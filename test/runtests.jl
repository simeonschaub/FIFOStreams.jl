using FIFOStreams
using Test

@static if VERSION >= v"1.3"
    using diffutils_jll
else
    _diff(f) = Sys.isunix() ? f("diff") : @test_broken false
end

@testset "diff" begin
    a = read(joinpath(@__DIR__, "a"), String)
    b = read(joinpath(@__DIR__, "b"), String)
    diff_ab = read(joinpath(@__DIR__, "diff_ab"), String)

    for T in [UnixFIFOStream, FallbackFIFOStream]
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
end
