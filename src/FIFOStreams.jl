module FIFOStreams

using Base: AbstractPipe, AbstractCmd, Redirectable, IOError, Process

export mkfifo, mktempfifo,
    AbstractFIFOStream, FIFOStream, UnixFIFOStream, FallbackFIFOStream,
    FIFOStreamCollection,
    attach, path

#####
##### Utility functions
#####

function mkfifo(path, mode)
    Sys.isunix() || error("`mkfifo` can't be used on non-Unix systems.")
    r = ccall(:mkfifo, Cint, (Cstring, UInt16), path, mode)
    r != 0 && throw(IOError("`mkfifo` returned exit code $r", r))
    return path
end

function mktempfifo(parent=tempdir(); mode=0o600, cleanup=true)
    return mkfifo(tempname(parent, cleanup=cleanup), mode)
end

function _mktemp(parent=tempdir(); mode=0o600, cleanup=true)
    path = tempname(parent, cleanup=cleanup)
    touch(path)
    chmod(path, mode)
    return path
end

#####
##### AbstractFIFOStream
#####

abstract type AbstractFIFOStream <: IO end

#####
##### FIFOStream
#####

@doc raw"""
    FIFOStream(path::String=_mktemp(); read=false, write=!read, cleanup=true)
      -> UnixFIFOStream (on Unix) / FallbackFIFOStream (on non-Unix)

An abstract type for either writing to, or reading from external commands through Unix
pipes or temporary files. All subtypes `T<:FIFOStream` implement the following interface:

1. Create stream `s`, optionally from specific path: `s = T([path::String]; opts...)`
2. Attach an external command that reads from / writes to that path:
   ```attach(s, `foo $(path(s))`[, stdios...])```
3. Write to / read from the stream, just like any other `IO` object
3. Close the stream with `close(s; rm=s.cleanup)`

# Examples
```jldoctest
julia> s = FIFOStream();

julia> io = IOBuffer();

julia> attach(s, pipeline(`cat $(path(s))`, stdout=io));

julia> print(s, "Hello, World!")

julia> close(s)

julia> Text(String(take!(io)))
Hello, World!

julia> s = FIFOStream(read=true);

julia> attach(s, `bash -c "echo 'Hello, World!' > $(path(s))"`);

julia> read(s, String)
"Hello, World!\n"

julia> close(s)
```
"""
abstract type FIFOStream <: AbstractFIFOStream end

function _parse_rw(read, write)
    write != read || throw(ArgumentError(
        "`Invalid arguments `write=$write, read=$read`. Can only open FIFOStream for" *
        "either write or read."
    ))
    return (UInt8(read) << 1) | UInt8(write)
end
function _deparse_rw(rw)
    @assert rw < 4
    return (; read = (rw >> 1) % Bool, write = rw % Bool)
end

mutable struct UnixFIFOStream <: FIFOStream
    path::String
    rw::UInt8
    cleanup::Bool
    iostream::IOStream
    attached_process::AbstractPipe
    function UnixFIFOStream(path::String=mktempfifo(); read=false, write=!read, cleanup=true)
        Sys.isunix() || error("`UnixFIFOStream` can't be used on non-Unix systems.")
        return new(path, _parse_rw(read, write), cleanup)
    end
end

mutable struct FallbackFIFOStream <: FIFOStream
    path::String
    rw::UInt8
    cleanup::Bool
    iostream::IOStream
    attached_cmd::AbstractCmd
    attached_stdios::Vector{Any}
    function FallbackFIFOStream(path::String=_mktemp(); read=false, write=!read, cleanup=true)
        return new(path, _parse_rw(read, write), cleanup)
    end
end

if Sys.isunix()
    FIFOStream(args...; kwargs...) = UnixFIFOStream(args...; kwargs...)
else
    FIFOStream(args...; kwargs...) = FallbackFIFOStream(args...; kwargs...)
end

Base.write(s::FIFOStream, x::UInt8) = write(s.iostream, x)
Base.unsafe_write(s::FIFOStream, p::Ptr{UInt8}, n::UInt) = unsafe_write(s.iostream, p, n)

Base.read(s::FIFOStream) = read(s.iostream)
Base.unsafe_read(s::FIFOStream, p::Ptr{UInt8}, n::UInt) = unsafe_read(s.iostream, p, n)

is_cmd_attached(s::UnixFIFOStream) = isdefined(s, :attached_process)
is_cmd_attached(s::FallbackFIFOStream) = isdefined(s, :attached_cmd)

function _init_fifo_cmd(s::UnixFIFOStream, cmd::AbstractCmd, stdios::Base.SpawnIOs)
    s.attached_process = Base._spawn(cmd, stdios)
    nothing
end
function _init_fifo_cmd(s::FallbackFIFOStream, cmd::AbstractCmd, stdios::Base.SpawnIOs)
    s.attached_cmd = cmd
    s.attached_stdios = stdios
    if _deparse_rw(s.rw).read
        process = Base._spawn(cmd, stdios)
        success(process) || Base.pipeline_error(process)
    end
    nothing
end

function attach(s::FIFOStream)
    isdefined(s, :iostream) &&
        throw(IOError("FIFOStream already has an IOStream attached.", 0))
    s.iostream = open(s.path; _deparse_rw(s.rw)...)
    return s
end
function attach(s::FIFOStream, cmd::AbstractCmd, stdios::Redirectable...)
    is_cmd_attached(s) &&
        throw(IOError("FIFOStream already has a Cmd attached.", 0))
    stdios = Base.spawn_opts_inherit(stdios...)
    _init_fifo_cmd(s, cmd, stdios)
    attach(s)
    return s
end

path(s::FIFOStream) = s.path
Base.rm(s::FIFOStream) = rm(path(s))

_fifo_process(s::UnixFIFOStream) = s.attached_process
function _fifo_process(s::FallbackFIFOStream)
    if _deparse_rw(s.rw).write
        return Base._spawn(s.attached_cmd, s.attached_stdios)
    else
        return nothing
    end
end

function Base.close(s::FIFOStream; rm=s.cleanup)
    isdefined(s, :iostream) && close(s.iostream)
    if !is_cmd_attached(s)
        rm && Base.rm(s)
        return
    end
    process = _fifo_process(s)::Union{Process,Nothing}
    succ = process !== nothing ? success(process) : true
    rm && Base.rm(s)
    succ || Base.pipeline_error(process::Process)
    nothing
end

#####
##### FIFOStreamCollection
#####

struct FIFOStreamCollection <: AbstractFIFOStream
    main::AbstractFIFOStream
    children::Vector{AbstractFIFOStream}
end

@doc raw"""
    FIFOStreamCollection([T::Type{<:FIFOStream}, ]n::Integer; opts...)

A collection of multiple `FIFOStream`s, for dealing with multiple streams conveniently.

# Examples
```jldoctest
julia> s = FIFOStreamCollection(2);

julia> io = IOBuffer();

julia> attach(s, pipeline(ignorestatus(`diff --side-by-side $(path(s, 1)) $(path(s, 2))`); stdout=io));

julia> s1, s2 = s;

julia> show(s1, code_lowered(cos, Tuple{Float64}))

julia> show(s2, code_lowered(sin, Tuple{Float64}))

julia> close(s)

julia> # Text(String(take!(io))) # uncomment to show diff
```
"""
function FIFOStreamCollection end
function FIFOStreamCollection(T::Type{<:FIFOStream}, n::Integer; opts...)
    n >= 1 || throw(ArgumentError("Number of streams has to be >= 1."))
    return FIFOStreamCollection(
        T(; opts...),
        AbstractFIFOStream[T(; opts...) for _ in 1:n-1],
    )
end
FIFOStreamCollection(n::Integer; opts...) = FIFOStreamCollection(FIFOStream, n; opts...)

function attach(s::FIFOStreamCollection, args...)
    attach(s.main, args...)
    foreach(attach, s.children)
    return s
end

Base.length(s::FIFOStreamCollection) = length(s.children) + 1

Base.iterate(s::FIFOStreamCollection) = s.main, 1
function Base.iterate(s::FIFOStreamCollection, i)
    return i <= length(s.children) ? (s.children[i], i + 1) : nothing
end

function Base.iterate(r::Iterators.Reverse{FIFOStreamCollection}, i=length(r.itr)-1)
    i < 0 && return nothing
    return i == 0 ? r.itr.main : r.itr.children[i], i - 1
end

function Base.close(s::FIFOStreamCollection; rm=nothing)
    foreach(s -> close(s; rm=false), Iterators.reverse(s))
    map(s) do s
        something(rm, s.cleanup) && Base.rm(s)
    end
    nothing
end

path(s::FIFOStreamCollection, i::Integer) = path(i == 1 ? s.main : s.children[i-1])

function __init__()
    # work around https://github.com/JuliaLang/julia/issues/39311
    if Sys.iswindows()
        sprint() do io
            run(pipeline(`echo foo`; stdout=io))
        end
    end
end

end
