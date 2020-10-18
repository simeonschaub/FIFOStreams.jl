using FIFOStreams
using Documenter

makedocs(;
    modules=[FIFOStreams],
    authors="Simeon Schaub <simeondavidschaub99@gmail.com> and contributors",
    repo="https://github.com/simeonschaub/FIFOStreams.jl/blob/{commit}{path}#L{line}",
    sitename="FIFOStreams.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://simeonschaub.github.io/FIFOStreams.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/simeonschaub/FIFOStreams.jl",
)
