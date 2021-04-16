using Pkg, Scratch, Preferences

# Use `cc` to build `sandbox.c` into a scratch space owned by `Sandbox`
sandbox_uuid = Base.UUID("9307e30f-c43e-9ca7-d17c-c2dc59df670d")
sdir = get_scratch!(sandbox_uuid, "local_sandbox")
sandbox_path = joinpath(sdir, "sandbox")
sandbox_src = joinpath(@__DIR__, "userns_sandbox.c")
run(`cc -std=c99 -O2 -static -static-libgcc -g -o $(sandbox_path) $(sandbox_src)`)

# Tell UserNSSandbox_jll to load our `sandbox` instead of the default artifact one
set_preferences!(
    joinpath(dirname(@__DIR__), "LocalPreferences.toml"),
    "UserNSSandbox_jll",
    "sandbox_path" => sandbox_path;
    force=true,
)
