using Test, LazyArtifacts, Sandbox

@testset "SandboxConfig" begin
    rootfs_dir = Sandbox.debian_rootfs()

    @testset "minimal config" begin
        config = SandboxConfig(Dict("/" => rootfs_dir))

        @test haskey(config.read_only_maps, "/")
        @test config.read_only_maps["/"] == rootfs_dir
        @test isempty(config.read_write_maps)
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
                "/lib" => "/lib",
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
        @test config.read_only_maps["/"] == rootfs_dir
        @test config.read_only_maps["/lib"] == "/lib"
        @test config.read_write_maps["/workspace"] == @__DIR__
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
end
