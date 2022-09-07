using FIFOStreams
using Test
using diffutils_jll

a = read(joinpath(@__DIR__, "a"), String)
b = read(joinpath(@__DIR__, "b"), String)
diff_ab = read(joinpath(@__DIR__, "diff_ab"), String)

for T in [(Sys.isunix() ? [UnixFIFOStream] : [])..., FallbackFIFOStream]

@testset "diffutils - $T" begin
    _diff() do diff
        s = FIFOStreamCollection(T, 2)
        io = IOBuffer()
        attach(s, pipeline(ignorestatus(`$diff $(path(s, 1)) $(path(s, 2))`); stdout=io))
        s1, s2 = s
        print(s1, a)
        print(s2, b)
        close(s)
        out = String(take!(io))
        @test out == diff_ab
    end
end

s = FIFOStream()
# just test that this doesn't error
@test close(s) === nothing

# doctests are broken on Windows, let's not bother
Sys.iswindows() && continue

using Documenter
DocMeta.setdocmeta!(
    FIFOStreams,
    :DocTestSetup,
    :(using FIFOStreams; const FIFOStream = $T);
    recursive=true,
)
@testset "doctests - $T" begin
    doctest(FIFOStreams)
end

end
