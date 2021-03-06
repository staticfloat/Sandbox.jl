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
                # Directory to hold read-writing from nested sandboxen
                rw_dir = joinpath(dir, "rw")
                mkpath(rw_dir)
                mkpath(joinpath(rw_dir, "home"))

                # Directory to hold sandbox persistence data
                persist_dir = mktempdir(get(ENV, "SANDBOX_PERSISTENCE_DIR", tempdir()))
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

                # Build environment mappings
                env = Dict(
                    "PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME" => "/tmp/readwrite/home",
                    # Because overlayfs nesting with persistence requires mounting an overlayfs with
                    # a non-tmpfs-hosted workdir, and that's illegal on top of another overlayfs, we
                    # need to thread our persistence mappings through to the client.  We do so by
                    # bind-mounting `/sandbox_persistence` into the sandbox for future recursive mountings
                    "SANDBOX_PERSISTENCE_DIR" => "/sandbox_persistence",
                )
                # If we're a nested sandbox, pass the forcing through
                if haskey(ENV, "FORCE_SANDBOX_MODE")
                    env["FORCE_SANDBOX_MODE"] = ENV["FORCE_SANDBOX_MODE"]
                end

                config = SandboxConfig(
                    ro_mappings,
                    Dict(
                        # Mount a temporary directory in as writable
                        "/tmp/readwrite" => rw_dir,
                        # Mount a directory to hold our persistent sandbox data
                        "/sandbox_persistence" => persist_dir,
                    ),
                    # Add the path to `julia` onto the path
                    env;
                    pwd = "/app",
                    uid = Sandbox.getuid(),
                    gid = Sandbox.getgid(),
                )

                cmd = `/bin/sh -c "julia --color=yes --project test/nested/nested_child.jl"`
                with_executor(executor) do exe
                    @test success(exe, config, cmd)
                end
                @test isfile(joinpath(rw_dir, "single_nested.txt"))
                @test isfile(joinpath(rw_dir, "double_nested.txt"))
                @test String(read(joinpath(rw_dir, "single_nested.txt"))) == "aperture\n"
                @test String(read(joinpath(rw_dir, "double_nested.txt"))) == "science\n"

                if executor <: DockerExecutor
                    stderr = IOBuffer()
                    config_with_stderr = SandboxConfig(
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
                        stderr = stderr,
                    )

                    for privileges in [:no_new_privileges, :unprivileged]
                        with_executor(executor; privileges) do exe
                            @test !success(exe, config_with_stderr, cmd)
                            # Ensure that we get the nested sandbox unable to run any nested sandboxing
                            @test occursin("Could not find any available executors", String(take!(stderr)))
                        end
                    end
                end
            end
        end
    end
end
