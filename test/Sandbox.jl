using Test, Sandbox

all_executors = Sandbox.all_executors

# Can we run `sudo` without a password?  If not, don't attempt to test the privileged runner
if !success(`sudo -k -n true`)
    all_executors = filter(exe -> !isa(exe, PrivilegedUserNamespacesExecutor), all_executors)
end

for executor in all_executors
    if !executor_available(executor)
        @error("Skipping $(executor) tests, as it does not seem to be available")
        continue
    end

    rootfs_dir = artifact"AlpineRootfs"
    @testset "$(executor) Sandboxing" begin
        @testset "capturing stdout/stderr" begin
            stdout = IOBuffer()
            stderr = IOBuffer()
            config = SandboxConfig(
                Dict("/" => rootfs_dir);
                stdout,
                stderr,
            )
            @test run(executor(), config, `/bin/sh -c "echo stdout; echo stderr >&2"`)
            @test String(take!(stdout)) == "stdout\n";
            @test String(take!(stderr)) == "stderr\n";
        end

        @testset "ignorestatus()" begin
            config = SandboxConfig(Dict("/" => rootfs_dir))
            @test_throws ProcessFailedException run(executor(), config, `/bin/sh -c "false"`)
            @test !run(executor(), config, ignorestatus(`/bin/sh -c "false"`))
        end

        @testset "environment passing" begin
            # Ensure all those pesky "special" variables make it through
            env = Dict(
                "PATH" => "for",
                "LD_LIBRARY_PATH" => "science",
                "DYLD_LIBRARY_PATH" => "you",
                "SHELL" => "monster",
            )
            stdout = IOBuffer()
            config = SandboxConfig(
                Dict("/" => rootfs_dir),
                Dict{String,String}(),
                env;
                stdout,
            )
            user_cmd = `/bin/sh -c "echo \$PATH \$LD_LIBRARY_PATH \$DYLD_LIBRARY_PATH \$SHELL"`
            @test run(executor(), config, user_cmd)
            @test String(take!(stdout)) == "for science you monster\n";

            # Test that setting some environment onto `user_cmd` can override the `config` env:
            user_cmd = setenv(user_cmd, "DYLD_LIBRARY_PATH" => "my", "SHELL" => "friend")
            @test run(executor(), config, user_cmd)
            @test String(take!(stdout)) == "for science my friend\n";
        end

        @testset "reading from maps" begin
            mktempdir() do dir
                open(joinpath(dir, "note.txt"), write=true) do io
                    write(io, "great success")
                end
                stdout = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir, "/glados" => dir);
                    stdout,
                )
                @test run(executor(), config, `/bin/sh -c "cat /glados/note.txt"`)
                @test String(take!(stdout)) == "great success";
            end
        end

        @testset "writing to workspaces" begin
            mktempdir() do dir
                stdout = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir),
                    Dict("/glados" => dir);
                )
                @test run(executor(), config, `/bin/sh -c "echo aperture > /glados/science.txt"`)
                @test isfile(joinpath(dir, "science.txt"))
                @test String(read(joinpath(dir, "science.txt"))) == "aperture\n"
            end
        end

        @testset "pipelining" begin
            pipe = PipeBuffer()
            stdout = IOBuffer()
            first_config = SandboxConfig(
                Dict("/" => rootfs_dir),
                stdout = pipe,
            )
            second_config = SandboxConfig(
                Dict("/" => rootfs_dir),
                stdin = pipe,
                stdout = stdout,
            )
            @test run(executor(), first_config, `/bin/sh -c "echo 'ignore me'; echo 'pick this up foo'; echo 'ignore me as well'"`)
            @test run(executor(), second_config, `/bin/sh -c "grep foo"`)
            @test String(take!(stdout)) == "pick this up foo\n";
        end

        @testset "read-only mounts are really read-only" begin
            mktempdir() do dir
                read_only_dir = joinpath(dir, "read_only")
                read_write_dir = joinpath(dir, "read_write")
                mkdir(read_only_dir)
                mkdir(read_write_dir)
                stdout = IOBuffer()
                stderr = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir, "/read_only" => read_only_dir),
                    Dict("/read_write" => read_write_dir),
                    stdout = stdout,
                    stderr = stderr,
                )
                # Modifying the rootfs works, and is temporary; for docker containers this is
                # modifying the rootfs image, for userns this is all mounted within an overlay backed by a tmpfs
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /bin/science && cat /bin/science"`)
                @test String(take!(stdout)) == "aperture\n";
                @test isempty(take!(stderr))
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /bin/science && cat /bin/science"`)
                @test String(take!(stdout)) == "aperture\n";
                @test isempty(take!(stderr))

                # An actual read-only mount will not work, because it's truly read-only
                @test !run(executor(), config, ignorestatus(`/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`))
                @test occursin("Read-only file system", String(take!(stderr)))

                # A read-write mount, on the other hand, will be permanent
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /read_write/science && cat /read_write/science"`)
                @test String(take!(stdout)) == "aperture\n";
                @test isempty(take!(stderr))
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /read_write/science && cat /read_write/science"`)
                @test String(take!(stdout)) == "aperture\naperture\n";
                @test isempty(take!(stderr))
            end
        end

        @testset "entrypoint" begin
            mktempdir() do dir
                read_only_dir = joinpath(dir, "read_only")
                mkdir(read_only_dir)
                stdout = IOBuffer()
                stderr = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir, "/read_only" => read_only_dir),
                    entrypoint = "/read_only/entrypoint",
                    stdout = stdout,
                    stderr = stderr,
                )

                # Generate an `entrypoint` script that mounts a tmpfs-backed overlayfs over our read-only mounts
                # Allowing us to write to those read-only mounts, but the changes are temporary
                open(joinpath(read_only_dir, "entrypoint"), write=true) do io
                    write(io, """
                    #!/bin/sh

                    echo entrypoint activated

                    mkdir /overlay_workdir
                    mount -t tmpfs -osize=1G tmpfs /overlay_workdir
                    mkdir -p /overlay_workdir/upper
                    mkdir -p /overlay_workdir/work
                    mount -t overlay overlay -olowerdir=/read_only -oupperdir=/overlay_workdir/upper -oworkdir=/overlay_workdir/work /read_only

                    exec "\$@"
                    """)
                end
                chmod(joinpath(read_only_dir, "entrypoint"), 0o755)

                # Modifying the read-only files now works, and is temporary
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`)
                @test String(take!(stdout)) == "entrypoint activated\naperture\n";
                @test isempty(take!(stderr))
                @test run(executor(), config, `/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`)
                @test String(take!(stdout)) == "entrypoint activated\naperture\n";
                @test isempty(take!(stderr))
            end
        end
    end
end