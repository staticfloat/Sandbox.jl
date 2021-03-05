using Documenter, Sandbox

makedocs(
    modules = [Sandbox],
    sitename = "Sandbox.jl",
)

deploydocs(
    repo = "github.com/staticfloat/Sandbox.jl.git",
    push_preview = true,
    devbranch = "main",
)
