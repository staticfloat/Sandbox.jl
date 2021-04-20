using Test, Sandbox, Scratch, Pkg

@testset "Nesting Sandbox.jl" begin
    all_executors = Sandbox.all_executors
    rootfs_dir = Sandbox.julia_alpine_rootfs()
    sandbox_dir = dirname(Sandbox.UserNSSandbox_jll.sandbox_path)
    for executor in all_executors
        if !executor_available(executor)
            @error("Skipping $(executor) tests, as it does not seem to be available")
            continue
        end

        # Nested sandboxing explicitly does not work with privileged user namespaces,
        # since the whole issue is that once we've dropped privileges the kernel cannot
        # sandbox properly (hence the need to use privileged executor at all).
        if executor <: PrivilegedUserNamespacesExecutor
            continue
        end

        @testset "$(executor) Nesting" begin
            pkgdir = dirname(@__DIR__)
            mktempdir() do dir
                rw_dir = joinpath(dir, "rw")
                mkpath(rw_dir)
                mkpath(joinpath(rw_dir, "home"))
                
                ro_mappings = Dict(
                    # Mount in the rootfs
                    "/" => rootfs_dir,
                    # Mount our package in at its own location
                    "/app" => pkgdir,
                    # On the off-chance that we're using a custom `sandbox`, make sure it's available at the path
                    # that the preferences set in `/app/Project.toml` will expect
                    sandbox_dir => sandbox_dir,
                )

                # Mount in `/etc/resolv.conf` as a read-only mount if using a UserNS executor, so that we have DNS
                if executor <: UserNamespacesExecutor && isfile("/etc/resolv.conf")
                    resolv_conf = joinpath(rw_dir, "resolv.conf")
                    cp("/etc/resolv.conf", resolv_conf; follow_symlinks=true)
                    ro_mappings["/etc/resolv.conf"] = resolv_conf
                end

                config = SandboxConfig(
                    ro_mappings,
                    # Mount a temporary directory in as writable
                    Dict("/tmp/readwrite" => rw_dir),
                    # Add the path to `julia` onto the path
                    Dict(
                        "PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin",
                        "HOME" => "/tmp/readwrite/home",
                    );
                    pwd = "/app",
                    uid = Sandbox.getuid(),
                    gid = Sandbox.getgid(),
                    #verbose = true,
                )

                with_executor(executor) do exe
                    @test success(run(exe, config, `/bin/sh -c "julia --color=yes --project test/nested/nested_child.jl"`))
                end
                @test isfile(joinpath(rw_dir, "single_nested.txt"))
                @test isfile(joinpath(rw_dir, "double_nested.txt"))
                @test String(read(joinpath(rw_dir, "single_nested.txt"))) == "aperture\n"
                @test String(read(joinpath(rw_dir, "double_nested.txt"))) == "science\n"
            end
        end
    end
end