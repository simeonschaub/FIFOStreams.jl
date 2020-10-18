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

abstract type FIFOStream <: AbstractFIFOStream end

mutable struct UnixFIFOStream <: FIFOStream
    path::String
    cleanup::Bool
    in::IOStream
    attached_process::AbstractPipe
    function UnixFIFOStream(path::String=mktempfifo(); cleanup=true)
        Sys.isunix() || error("`UnixFIFOStream` can't be used on non-Unix systems.")
        return new(path, cleanup)
    end
end

mutable struct FallbackFIFOStream <: FIFOStream
    path::String
    cleanup::Bool
    in::IOStream
    attached_cmd::AbstractCmd
    attached_stdios::Vector{Any}
    FallbackFIFOStream(path::String=_mktemp(); cleanup=true) = new(path, cleanup)
end

if Sys.isunix()
    FIFOStream(args...; kwargs...) = UnixFIFOStream(args...; kwargs...)
else
    FIFOStream(args...; kwargs...) = FallbackFIFOStream(args...; kwargs...)
end

Base.write(s::FIFOStream, x::UInt8) = write(s.in, x)
Base.unsafe_write(s::FIFOStream, p::Ptr{UInt8}, n::UInt) = unsafe_write(s.in, p, n)

is_cmd_attached(s::UnixFIFOStream) = isdefined(s, :attached_process)
is_cmd_attached(s::FallbackFIFOStream) = isdefined(s, :attached_cmd)

function _init_fifo_cmd(s::UnixFIFOStream, cmd::AbstractCmd, stdios::Vector{Any})
    s.attached_process = Base._spawn(cmd, stdios)
    nothing
end
function _init_fifo_cmd(s::FallbackFIFOStream, cmd::AbstractCmd, stdios::Vector{Any})
    s.attached_cmd = cmd
    s.attached_stdios = stdios
    nothing
end

function attach(s::FIFOStream)
    isdefined(s, :in) &&
        throw(IOError("FIFOStream already has an IOStream attached.", 0))
    s.in = open(s.path, "w")
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
_fifo_process(s::FallbackFIFOStream) = Base._spawn(s.attached_cmd, s.attached_stdios)

function Base.close(s::FIFOStream; rm=s.cleanup)
    close(s.in)
    if !is_cmd_attached(s)
        rm && Base.rm(s)
        return
    end
    process = _fifo_process(s)::Process
    succ = success(process)
    rm && Base.rm(s)
    succ || Base.pipeline_error(process)
    nothing
end

#####
##### FIFOStreamCollection
#####

struct FIFOStreamCollection <: AbstractFIFOStream
    main::AbstractFIFOStream
    children::Vector{AbstractFIFOStream}
end

function FIFOStreamCollection(n::Integer)
    n >= 1 || throw(ArgumentError("Number of streams has to be >= 1."))
    return FIFOStreamCollection(
        FIFOStream(),
        AbstractFIFOStream[FIFOStream() for _ in 1:n-1],
    )
end

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

end
