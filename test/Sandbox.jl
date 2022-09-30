using Test, Sandbox, SHA, Base.BinaryPlatforms

all_executors = Sandbox.all_executors

# Can we run `sudo` without a password?  If not, don't attempt to test the privileged runner
if !success(`sudo -k -n true`)
    all_executors = filter(exe -> exe != PrivilegedUserNamespacesExecutor, all_executors)
end

function print_if_nonempty(stderr::Vector{UInt8})
    if !isempty(stderr)
        stderr = String(stderr)
        @error("not empty")
        println(stderr)
        return false
    end
    return true
end

rootfs_dir = Sandbox.debian_rootfs()
for executor in all_executors
    if !executor_available(executor)
        @error("Skipping $(executor) tests, as it does not seem to be available")
        continue
    end

    @testset "$(executor) Sandboxing" begin
        @testset "capturing stdout/stderr" begin
            stdout = IOBuffer()
            stderr = IOBuffer()
            config = SandboxConfig(
                Dict("/" => rootfs_dir);
                stdout,
                stderr,
            )
            with_executor(executor) do exe
                @test success(exe, config, `/bin/sh -c "echo stdout; echo stderr >&2"`)
                @test String(take!(stdout)) == "stdout\n";
                @test String(take!(stderr)) == "stderr\n";
            end
        end

        @testset "ignorestatus()" begin
            config = SandboxConfig(Dict("/" => rootfs_dir))
            with_executor(executor) do exe
                @test_throws ProcessFailedException run(exe, config, `/bin/sh -c "false"`)
                @test !success(exe, config, ignorestatus(`/bin/sh -c "false"`))
            end
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
            with_executor(executor) do exe
                @test success(exe, config, user_cmd)
                @test String(take!(stdout)) == "for science you monster\n";
            end

            # Test that setting some environment onto `user_cmd` can override the `config` env:
            user_cmd = setenv(user_cmd, "DYLD_LIBRARY_PATH" => "my", "SHELL" => "friend")
            with_executor(executor) do exe
                @test success(exe, config, user_cmd)
                @test String(take!(stdout)) == "for science my friend\n";
            end
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
                with_executor(executor) do exe
                    @test success(exe, config, `/bin/sh -c "cat /glados/note.txt"`)
                    @test String(take!(stdout)) == "great success";
                end
            end
        end

        @testset "writing to workspaces" begin
            mktempdir() do dir
                stdout = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir),
                    Dict("/glados" => dir);
                )
                @test success(executor(), config, `/bin/sh -c "echo aperture > /glados/science.txt"`)
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
            @test success(executor(), first_config, `/bin/sh -c "echo 'ignore me'; echo 'pick this up foo'; echo 'ignore me as well'"`)
            @test success(executor(), second_config, `/bin/sh -c "grep foo"`)
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
                    persist = false,
                )
                # Modifying the rootfs works, and is temporary; for docker containers this is modifying
                # the rootfs image, for userns this is all mounted within an overlay backed by a tmpfs,
                # because we have `persist` set to `false`.
                with_executor(executor) do exe
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /bin/science && cat /bin/science"`)
                    @test String(take!(stdout)) == "aperture\n";
                    @test print_if_nonempty(take!(stderr))
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /bin/science && cat /bin/science"`)
                    @test String(take!(stdout)) == "aperture\n";
                    @test print_if_nonempty(take!(stderr))

                    # An actual read-only mount will not allow writing, because it's truly read-only
                    @test !success(exe, config, ignorestatus(`/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`))
                    @test occursin("Read-only file system", String(take!(stderr)))

                    # A read-write mount, on the other hand, will be permanent
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /read_write/science && cat /read_write/science"`)
                    @test String(take!(stdout)) == "aperture\n";
                    @test print_if_nonempty(take!(stderr))
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /read_write/science && cat /read_write/science"`)
                    @test String(take!(stdout)) == "aperture\naperture\n";
                    @test print_if_nonempty(take!(stderr))
                end
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
                with_executor(executor) do exe
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`)
                    @test String(take!(stdout)) == "entrypoint activated\naperture\n";
                    @test print_if_nonempty(take!(stderr))
                    @test success(exe, config, `/bin/sh -c "echo aperture >> /read_only/science && cat /read_only/science"`)
                    @test String(take!(stdout)) == "entrypoint activated\naperture\n";
                    @test print_if_nonempty(take!(stderr))
                end
            end
        end

        @testset "persistence" begin
            mktempdir() do dir
                stdout = IOBuffer()
                stderr = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => rootfs_dir),
                    stdout = stdout,
                    stderr = stderr,
                    persist = true,
                )

                # Modifying the read-only files is persistent within a single executor
                cmd = `/bin/sh -c "echo aperture >> /bin/science && cat /bin/science"`
                with_executor(executor) do exe
                    @test success(exe, config, cmd)
                    @test String(take!(stdout)) == "aperture\n";
                    @test print_if_nonempty(take!(stderr))
                    @test success(exe, config, cmd)
                    @test String(take!(stdout)) == "aperture\naperture\n";
                    @test print_if_nonempty(take!(stderr))
                end

                with_executor(executor) do exe
                    @test success(exe, config, cmd)
                    @test String(take!(stdout)) == "aperture\n";
                    @test print_if_nonempty(take!(stderr))
                end
            end
        end

        @testset "explicit user and group" begin
            for (uid,gid) in [(0,0), (999,0), (0,999), (999,999)]
                stdout = IOBuffer()

                config = SandboxConfig(
                    Dict("/" => rootfs_dir);
                    stdout, uid, gid
                )
                with_executor(executor) do exe
                    @test success(exe, config, `/usr/bin/id`)
                    str = String(take!(stdout))
                    @test contains(str, "uid=$(uid)")
                    @test contains(str, "gid=$(gid)")
                end
            end
        end

        # If we have the docker executor available (necessary to do the initial pull),
        # let's test launching off of a docker image.  Only run this on x86_64 because
        # docker doesn't (yet) have images with this name for other architectures.
        if executor_available(DockerExecutor) && arch(HostPlatform()) == "x86_64"
            julia_rootfs = Sandbox.pull_docker_image("julia:alpine")
            @testset "launch from docker image" begin
                stdout = IOBuffer()
                stderr = IOBuffer()
                config = SandboxConfig(
                    Dict("/" => julia_rootfs),
                    Dict{String,String}(),
                    # Add the path to `julia` onto the path, then use `sh` to process the PATH
                    Dict("PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin");
                    stdout = stdout,
                    stderr = stderr,
                )

                with_executor(executor) do exe
                    @test success(exe, config, `/bin/sh -c "julia -e 'println(\"Hello, Julia!\")'"`)
                    @test String(take!(stdout)) == "Hello, Julia!\n";
                    @test print_if_nonempty(take!(stderr))
                end
            end
        end

        @testset "hostname" begin
            stdout = IOBuffer()

            config = SandboxConfig(
                Dict("/" => rootfs_dir);
                stdout,
                hostname="sandy",
            )
            with_executor(executor) do exe
                @test success(exe, config, `/bin/uname -n`)
                @test chomp(String(take!(stdout))) == "sandy"
            end
        end

        @testset "Internet access" begin
            mktempdir() do rw_dir
                ro_mappings = Dict(
                    "/" => rootfs_dir,
                )

                # Mount in `/etc/resolv.conf` as a read-only mount if using a UserNS executor, so that we have DNS
                if executor <: UserNamespacesExecutor && isfile("/etc/resolv.conf")
                    resolv_conf = joinpath(rw_dir, "resolv.conf")
                    cp("/etc/resolv.conf", resolv_conf; follow_symlinks=true)
                    ro_mappings["/etc/resolv.conf"] = resolv_conf
                end

                # Do a test with the debian rootfs where we try to use `apt` to install `curl`, then use that to download something.
                socrates_url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.xz"
                socrates_hash = "61bcf109fcb749ee7b6a570a6057602c08c836b6f81091eab7aa5f5870ec6475"
                config = SandboxConfig(
                    ro_mappings,
                    Dict("/tmp/rw_dir" => rw_dir),
                    Dict("HOME" => "/root"),
                )
                with_executor(executor) do exe
                    @test success(exe, config, `/bin/sh -c "apt update && apt install -y curl && curl -L $(socrates_url) -o /tmp/rw_dir/$(basename(socrates_url))"`)
                end
                socrates_path = joinpath(rw_dir, basename(socrates_url))
                @test isfile(socrates_path)
                @test open(io -> bytes2hex(sha256(io)), socrates_path) == socrates_hash
            end
        end
    end
end


@testset "default executor" begin
    stdout = IOBuffer()
    stderr = IOBuffer()
    config = SandboxConfig(
        Dict("/" => rootfs_dir);
        stdout,
        stderr,
    )
    with_executor() do exe
        @test success(exe, config, `/bin/sh -c "echo stdout; echo stderr >&2"`)
        @test String(take!(stdout)) == "stdout\n";
        @test String(take!(stderr)) == "stderr\n";
    end
end
