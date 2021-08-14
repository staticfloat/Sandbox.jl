# When we are a child, we do the following:
# 1. Set up a temp directory that we can write to.
# 2. Copy the contents of our package from `/app` (which is read-only) to our temp
#    directory (which is read-and-write).
# 3. Delete any manifest files in the temp directory,.
# 4. Instantiate the environment inside our temp directory.
original_app_directory = "/app" # this is read-only; we cannot write to this directory
new_app_directory = mktempdir(; cleanup = true) # we have write access to this directory
for element in readdir(original_app_directory)
    old_path = joinpath(original_app_directory, element)
    new_path = joinpath(new_app_directory,      element)
    cp(old_path, new_path; force = true)
end
rm.(joinpath.(Ref(new_app_directory), Base.manifest_names); force = true)
ENV["JULIA_PKG_SERVER"] = ""
using Pkg
Pkg.activate(new_app_directory)
Pkg.instantiate()
Pkg.precompile()

# Load Sandbox, then try to launch a nested sandbox
using Sandbox, Test

rootfs_dir = Sandbox.alpine_rootfs()

config = SandboxConfig(
    # This rootfs was downloaded within the sandbox in the `Pkg.instantiate()` above
    Dict("/" => rootfs_dir),
    # Propagate our readwrite mounting into the nested sandbox
    Dict{String,String}("/tmp/readwrite" => "/tmp/readwrite"),
    persist=true,
    verbose=true,
)

# Prove that we can write into the `readwrite` location
open("/tmp/readwrite/single_nested.txt", "w") do io
    println(io, "aperture")
end

# This should always default to the unprivileged executor, since if we're nested, `FORCE_SANDBOX_MODE` should be set
with_executor() do exe
    @test success(exe, config, `/bin/sh -c "echo science > /tmp/readwrite/double_nested.txt"`)
end
@test String(read("/tmp/readwrite/double_nested.txt")) == "science\n"
