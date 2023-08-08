using Test, Sandbox, Base.BinaryPlatforms, LazyArtifacts

@testset "multiarch" begin
    # This is a set of multiarch platforms that is _not_ our current platform
    native_arch = arch(HostPlatform())
    sub_arch = native_arch
    if native_arch == "x86_64"
        sub_arch = "i686"

    # Disabled for now
    #elseif native_arch == "aarch64"
    #    sub_arch = "armv7l"
    end
    alien_arch = native_arch ∈ ("x86_64", "i686") ? "aarch64" : "x86_64"
    @testset "argument parsing" begin
        # Test that our `multiarch` kwarg is correctly parsed
        config = SandboxConfig(
            Dict("/" => Sandbox.multiarch_rootfs());
            multiarch = [
                Platform(alien_arch, "linux"; libc="glibc"),
                Platform(alien_arch, "linux"; libc="musl"),
                Platform(native_arch, "linux"; libgfortran_version=v"4"),
                Platform(native_arch, "linux"; libgfortran_version=v"5"),
                Platform(sub_arch, "linux"),
            ],
        )

        # qemu doesn't care about `libc` or `libgfortran_version` or anything like that.
        # Also, native architectures (and sub-architectures such as `i686` for `x86_64`,
        # or `armv7l` for `aarch64`) get ignored, so we end up with only one multiarch
        # format from all that above, which is just `alien_arch`.
        @test length(config.multiarch_formats) == 1
        @test occursin(alien_arch, config.multiarch_formats[1].name)
    end

    # Of our available executors, let's check to see if each can be used to run multiarch workloads
    multiarch_executors = filter(executor_available, Sandbox.all_executors)
    old_binfmt_misc_regs = nothing

    if get(ENV, "SANDBOX_TEST_MULTIARCH", "true") != "true"
        @warn("Refusing to test multiarch because SANDBOX_TEST_MULTIARCH set to $(ENV["SANDBOX_TEST_MULTIARCH"])")
        multiarch_executors = Sandbox.SandboxExecutor[]
    elseif Sys.islinux()
        # On Linux, we need passwordless sudo to be able to register things
        if Sys.which("sudo") !== nothing && !success(`sudo -k -n true`)
            @warn("Refusing to test multiarch on a system without passwordless sudo!")
            multiarch_executors = Sandbox.SandboxExecutor[]
        end

        # Otherwise, let's save the current set of binfmt_misc registrations
        old_binfmt_misc_regs = Sandbox.read_binfmt_misc_registrations()
    end

    for executor in multiarch_executors
        if Sys.islinux()
            # Start by clearing out the binfmt_misc registrations, so that each executor
            # has to set things up from scratch.
            Sandbox.clear_binfmt_misc_registrations!()
        end

        @testset "HelloWorldC_jll" begin
            multiarch = [
                Platform("x86_64", "linux"; libc="glibc"),
                Platform("x86_64", "linux"; libc="musl"),
                Platform("i686", "linux"; libc="glibc"),
                Platform("i686", "linux"; libc="musl"),
                Platform("aarch64", "linux"; libc="glibc"),
                Platform("aarch64", "linux"; libc="musl"),
                Platform("armv7l", "linux"; libc="glibc"),
                Platform("armv7l", "linux"; libc="musl"),
                Platform("powerpc64le", "linux"; libc="glibc"),
                # We don't have this one yet
                #Platform("powerpc64le", "linux"; libc="musl"),
            ]
            stdout = IOBuffer()
            stderr = IOBuffer()
            config = SandboxConfig(
                Dict(
                    "/" => Sandbox.multiarch_rootfs(),
                    "/apps" => LazyArtifacts.ensure_artifact_installed("multiarch-testing", joinpath(dirname(@__DIR__), "Artifacts.toml")),
                );
                multiarch,
                stdout,
                stderr,
            )

            # Ensure that we're going to try and install some of these formats
            @test !isempty(config.multiarch_formats)

            with_executor(executor) do exe
                for platform in multiarch
                    @testset "$(platform)" begin
                        @test success(exe, config, `/apps/hello_world.$(triplet(platform))`)
                        @test String(take!(stdout)) == "Hello, World!\n";
                        @test isempty(String(take!(stderr)))
                    end
                end
            end
        end
    end

    if old_binfmt_misc_regs !== nothing && !isempty(old_binfmt_misc_regs)
        # Restore old binfmt_misc registrations so that our test suite isn't clobbering things for others
        Sandbox.clear_binfmt_misc_registrations!()
        Sandbox.write_binfmt_misc_registration!.(old_binfmt_misc_regs)
    end
end
