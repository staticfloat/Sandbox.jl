using Test, Sandbox

if Sys.islinux()
    @test isa(Sandbox.get_kernel_version(), VersionNumber)
    @test Sandbox.check_kernel_version()
end

if executor_available(UnprivilegedUserNamespacesExecutor)
    @testset "UnprivilegedUserNamespacesExecutor" begin
        @test_logs (:info, "Testing Unprivileged User Namespaces Executor (read-only, read-write)") begin
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test probe_executor(exe; test_read_only_map=true, test_read_write_map=true, verbose=true)
            end
        end
    end
    @testset "Customize the tempfs size" begin
        rootfs_dir = Sandbox.alpine_rootfs()
        read_only_maps = Dict("/" => rootfs_dir)
        read_write_maps = Dict{String, String}()
        env = Dict(
            "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "HOME" => "/home/juliaci",
            "USER" => "juliaci",
        )
        cmd = `/bin/sh -c "mkdir -p /home/juliaci && cd /home/juliaci && dd if=/dev/urandom of=sample.txt bs=50M count=1"`
        @testset "tempfs is big enough" begin
            config = SandboxConfig(read_only_maps, read_write_maps, env; tmpfs_size = "1G")
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test success(exe, config, cmd)
            end
        end
        @testset "tempfs is too small" begin
            config = SandboxConfig(read_only_maps, read_write_maps, env; tmpfs_size = "10M")
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test !success(exe, config, cmd)
            end
        end
    end
else
    @error("Skipping Unprivileged tests, as it does not seem to be available")
end

# Only test privileged runner if sudo doesn't require a password
if success(`sudo -k -n true`)
    if executor_available(PrivilegedUserNamespacesExecutor)
        @testset "PrivilegedUserNamespacesExecutor" begin
            @test_logs (:info, "Testing Privileged User Namespaces Executor (read-only, read-write)") begin
                with_executor(PrivilegedUserNamespacesExecutor) do exe
                    @test probe_executor(exe; test_read_only_map=true, test_read_write_map=true, verbose=true)
                end
            end
        end
    else
        @error("Skipping Privileged tests, as it does not seem to be available")
    end
end
