run(`ls -la /`)
run(`ls -la /tmp/readwrite`)
@info("uid_map/gid_map")
run(`cat /proc/self/uid_map`)
run(`cat /proc/self/gid_map`)


# Instantiate as when we're a child, we may not be instantiated
using Pkg
Pkg.instantiate()

# Load Sandbox, then try to launch a nested sandbox
using Sandbox, Test

rootfs_dir = Sandbox.alpine_rootfs()

config = SandboxConfig(
    # This rootfs was downloaded within the sandbox in the `Pkg.instantiate()` above
    Dict("/" => rootfs_dir),
    # Propagate our readwrite mounting into the nested sandbox
    Dict{String,String}("/tmp/readwrite" => "/tmp/readwrite"),
)

open("/tmp/readwrite/single_nested.txt", "w") do io
    println(io, "aperture")
end
# This should always default to the unprivileged executor, since if we're nested, `FORCE_SANDBOX_MODE` should be set
with_executor() do exe
    @test success(run(exe, config, `/bin/sh -c "echo science > /tmp/readwrite/double_nested.txt"`))
end
@test String(read("/tmp/readwrite/double_nested.txt")) == "science\n"