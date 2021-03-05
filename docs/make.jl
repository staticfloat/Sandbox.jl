using Documenter, Sandbox

makedocs(
    modules = [Sandbox],
    sitename = "Sandbox.jl",
)

deploydocs(
    repo = "github.com/staticfloat/Sandbo.jl.git",
    push_preview = true,
    devbranch = "main",
)
