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
        with_temp_scratch() do
            # With a temporary scratch directory, let's start by testing load/save timestamps
            @test !isfile(Sandbox.timestamps_path())
            @test isempty(Sandbox.load_timestamps())
            Sandbox.save_timestamp("foo", 1.0)
            @test isfile(Sandbox.timestamps_path())
            timestamps = Sandbox.load_timestamps()
            @test timestamps["foo"] == 1.0

            # Next, let's actually create a docker image out of our alpine rootfs image
            mktempdir() do rootfs_path
                cp(Sandbox.alpine_rootfs(), rootfs_path; force=true)
                @test Sandbox.should_build_docker_image(rootfs_path)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(rootfs_path; verbose=true)
                end

                # Ensure that it doesn't try to build again since the content is unchanged
                @test !Sandbox.should_build_docker_image(rootfs_path)
                @test_logs begin
                    Sandbox.build_docker_image(rootfs_path; verbose=true)
                end

                # Change the content
                chmod(joinpath(rootfs_path, "bin", "busybox"), 0o775)
                @test Sandbox.should_build_docker_image(rootfs_path)
                @test_logs (:info, r"Building docker image") match_mode=:any begin
                    Sandbox.build_docker_image(rootfs_path; verbose=true)
                end

                # Ensure that it once again doesn't try to build
                @test !Sandbox.should_build_docker_image(rootfs_path)
                @test_logs begin
                    Sandbox.build_docker_image(rootfs_path; verbose=true)
                end
            end
        end

        @testset "probe_executor" begin
            @test_logs (:info, "Testing Docker Executor (read-only, read-write)") begin
                with_executor(DockerExecutor) do exe
                    @test probe_executor(exe; test_read_only_map=true, test_read_write_map=true, verbose=true)
                end
            end
        end
    end
else
    @error("Skipping Docker tests, as it does not seem to be available")
end