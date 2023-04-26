using Test, Sandbox, Scratch, Base.BinaryPlatforms

function with_temp_scratch(f::Function)
    mktempdir() do scratch_dir
        with_scratch_directory(scratch_dir) do
            f()
        end
    end
end

if executor_available(DockerExecutor)
    @testset "Docker" begin
        uid = Sandbox.getuid()
        gid = Sandbox.getgid()
        with_temp_scratch() do
            # With a temporary scratch directory, let's start by testing load/save timestamps
            @test !isfile(Sandbox.timestamps_path())
            @test isempty(Sandbox.load_timestamps())
            Sandbox.save_timestamp("foo", 1.0)
            @test isfile(Sandbox.timestamps_path())
            timestamps = Sandbox.load_timestamps()
            @test timestamps["foo"] == 1.0

            # Next, let's actually create a docker image out of our debian rootfs image
            mktempdir() do rootfs_path; mktempdir() do data_path
                mounts = Dict(
                    "/" => MountInfo(rootfs_path, MountType.Overlayed),
                    "/data" => MountInfo(data_path, MountType.Overlayed),
                )
                overlay_mounts = Dict(p => m.host_path for (p, m) in mounts if m.type == MountType.Overlayed)
                cp(Sandbox.debian_rootfs(), rootfs_path; force=true)
                @test Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end

                # Ensure that it doesn't try to build again since the content is unchanged
                @test !Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end

                # Change the content
                chmod(joinpath(rootfs_path, "bin", "bash"), 0o775)
                @test Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end

                # Ensure that it once again doesn't try to build
                @test !Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end

                # change the content of `/data`:
                touch(joinpath(data_path, "foo"))
                @test Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end

                # Ensure that it once again doesn't try to build
                @test !Sandbox.should_build_docker_image(overlay_mounts, uid, gid)
                @test_logs begin
                    Sandbox.build_docker_image(mounts, uid, gid; verbose=true)
                end
            end; end
        end

        @testset "probe_executor" begin
            with_executor(DockerExecutor) do exe
                @test probe_executor(exe)
            end
        end

        @testset "pull_docker_image" begin
            curr_arch = arch(HostPlatform())
            platform = nothing
            if curr_arch == "x86_64"
                platform = "linux/amd64"
            elseif curr_arch == "aarch64"
                platform = "linux/arm64"
            end
            with_temp_scratch() do
                julia_rootfs = Sandbox.pull_docker_image("julia:latest"; force=true, verbose=true, platform)

                @test_logs (:warn, r"Will not overwrite") begin
                    other_julia_rootfs = Sandbox.pull_docker_image("julia:latest"; verbose=true, platform)
                    @test other_julia_rootfs == julia_rootfs
                end

                @test_logs (:warn, r"Cannot pull") begin
                    @test Sandbox.pull_docker_image("pleasenooneactuallycreateanimagenamedthis"; verbose=true) === nothing
                end

                @test julia_rootfs !== nothing
                @test isdir(julia_rootfs)

                # Ensure it pulls a rootfs that actually contains `julia`
                @test isfile(joinpath(julia_rootfs, "usr", "local", "julia", "bin", "julia"))
            end
        end
    end
else
    @error("Skipping Docker tests, as it does not seem to be available")
end
