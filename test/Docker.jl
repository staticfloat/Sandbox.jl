using Test, Sandbox, Scratch

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
            mktempdir() do rootfs_path
                cp(Sandbox.debian_rootfs(), rootfs_path; force=true)
                @test Sandbox.should_build_docker_image(rootfs_path, uid, gid)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(rootfs_path, uid, gid; verbose=true)
                end

                # Ensure that it doesn't try to build again since the content is unchanged
                @test !Sandbox.should_build_docker_image(rootfs_path, uid, gid)
                @test_logs begin
                    Sandbox.build_docker_image(rootfs_path, uid, gid; verbose=true)
                end

                # Change the content
                chmod(joinpath(rootfs_path, "bin", "bash"), 0o775)
                @test Sandbox.should_build_docker_image(rootfs_path, uid, gid)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(rootfs_path, uid, gid; verbose=true)
                end

                # Ensure that it once again doesn't try to build
                @test !Sandbox.should_build_docker_image(rootfs_path, uid, gid)
                @test_logs begin
                    Sandbox.build_docker_image(rootfs_path, uid, gid; verbose=true)
                end
            end
        end

        @testset "probe_executor" begin
            with_executor(DockerExecutor) do exe
                @test probe_executor(exe)
            end
        end

        @testset "pull_docker_image" begin
            with_temp_scratch() do
                julia_rootfs = Sandbox.pull_docker_image("julia:alpine"; force=true, verbose=true, platform="linux/amd64")

                @test_logs (:warn, r"Will not overwrite") begin
                    other_julia_rootfs = Sandbox.pull_docker_image("julia:alpine"; verbose=true, platform="linux/amd64")
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
