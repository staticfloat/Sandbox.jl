using Test, LazyArtifacts, Sandbox

@testset "SandboxConfig" begin
    rootfs_dir = Sandbox.debian_rootfs()

    @testset "minimal config" begin
        config = SandboxConfig(Dict("/" => rootfs_dir))

        @test haskey(config.mounts, "/")
        @test config.mounts["/"].host_path == realpath(rootfs_dir)
        @test isempty([m for (k, m) in config.mounts if m.type == MountType.ReadWrite])
        @test isempty(config.env)
        @test config.pwd == "/"
        @test config.stdin == Base.devnull
        @test config.stdout == Base.stdout
        @test config.stderr == Base.stderr
        @test config.hostname === nothing
    end

    @testset "full options" begin
        stdout = IOBuffer()
        config = SandboxConfig(
            # read-only maps
            Dict(
                "/" => rootfs_dir,
                "/lib" => rootfs_dir,
            ),
            # read-write maps
            Dict("/workspace" => @__DIR__),
            # env
            Dict("PATH" => "/bin:/usr/bin");
            entrypoint = "/init",
            pwd = "/lib",
            persist = true,
            stdin = Base.stdout,
            stdout = stdout,
            stderr = Base.devnull,
            hostname="sandy",
        )

        # Test the old style API getting mapped to the new MountInfo API:
        @test config.mounts["/"].host_path == realpath(rootfs_dir)
        @test config.mounts["/"].type == MountType.Overlayed
        @test config.mounts["/lib"].host_path == realpath(rootfs_dir)
        @test config.mounts["/lib"].type == MountType.ReadOnly
        @test config.mounts["/workspace"].host_path == realpath(@__DIR__)
        @test config.mounts["/workspace"].type == MountType.ReadWrite

        @test config.env["PATH"] == "/bin:/usr/bin"
        @test config.entrypoint == "/init"
        @test config.pwd == "/lib"
        @test config.persist
        @test config.stdin == Base.stdout
        @test config.stdout == stdout
        @test config.stderr == Base.devnull
        @test config.hostname == "sandy"
    end

    @testset "errors" begin
        # No root dir error
        @test_throws ArgumentError SandboxConfig(Dict("/rootfs" => rootfs_dir))

        # relative dirs error
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir, "rootfs" => rootfs_dir))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir, "/rootfs" => basename(rootfs_dir)))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir), Dict("rootfs" => rootfs_dir))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir), Dict("/rootfs" => basename(rootfs_dir)))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir); pwd="lib")
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir); entrypoint="init")
    end

    using Sandbox: realpath_stem
    @testset "realpath_stem" begin
        mktempdir() do dir
            dir = realpath(dir)
            mkdir(joinpath(dir, "bar"))
            touch(joinpath(dir, "bar", "foo"))
            symlink("foo", joinpath(dir, "bar", "l_foo"))
            symlink("bar", joinpath(dir, "l_bar"))
            symlink(joinpath(dir, "l_bar", "foo"), joinpath(dir, "l_bar_foo"))

            # Test that `realpath_stem` works just like `realpath()` on existent paths:
            existent_paths = [
                joinpath(dir, "bar"),
                joinpath(dir, "bar", "foo"),
                joinpath(dir, "bar", "l_foo"),
                joinpath(dir, "l_bar"),
                joinpath(dir, "l_bar", "foo"),
                joinpath(dir, "l_bar", "l_foo"),
                joinpath(dir, "l_bar_foo"),
            ]
            for path in existent_paths
                @test realpath_stem(path) == realpath(path)
            end

            # Test that `realpath_stem` gives good answers for non-existent paths:
            non_existent_path_mappings = [
                joinpath(dir, "l_bar", "spoon") => joinpath(dir, "bar", "spoon"),
                joinpath(dir, "l_bar", "..", "l_bar", "spoon") => joinpath(dir, "bar", "spoon"),
            ]
            for (non_path, path) in non_existent_path_mappings
                @test realpath_stem(non_path) == path
            end
        end
    end
end
