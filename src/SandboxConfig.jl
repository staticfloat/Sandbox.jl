using Base.BinaryPlatforms
const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, <:IO}

"""
    SandboxConfig(read_only_maps, read_write_maps, env)

Sandbox executors require a configuration to set up the environment properly.

- `read_only_maps`: Directories that are mapped into the sandbox as read-only mappings.
   - Specified as pairs, e.g. `sandbox_path => host_path`.  All paths must be absolute.
   - Must always include a mapping for root, e.g. `"/" => rootfs_path`.

- `read_write_maps`: Directories that are mapped into the sandbox as read-write mappings.
   - Specified as pairs, e.g. `sandbox_path => host_path`.  All paths must be absolute.
   - Note that some executors may not show perfect live updates; consistency is guaranteed
     only after execution is finished.

- `env`: Dictionary mapping of environment variables that should be set within the sandbox.

- `entrypoint`: Executable that gets passed the actual command being run.
  - This is a path within the sandbox, and must be absolute.
  - Defaults to `nothing`, which causes the command to be executed directly.

- `pwd`: Set the working directory of the command that will be run.
  - This is a path within the sandbox, and must be absolute.

- `persist`: Tell the executor object to persist changes made to the rootfs.
  - This is a boolean value, it is up to interpretation by the executor.
  - Persistence is a property of an individual executor and changes live only as long
    as the executor object itself.
  - You cannot transfer persistent changes from one executor to another.

- `multiarch`: Request multiarch executable support
  - This is an array of `Platform` objects
  - Sandbox will ensure that interpreters (such as `qemu-*-static` binaries) are
    available for each platform.
  - Requesting multiarch support for a platform that we don't support results in
    an `ArgumentError`.

- `uid` and `gid`: Numeric user and group identifiers to spawn the sandboxed process as.
  - By default, these are both `0`, signifying `root` inside the sandbox.

- `stdin`, `stdout`, `stderr`: input/output streams for the sandboxed process.
  - Can be any kind of `IO`, `TTY`, `devnull`, etc...

- `hostname`: Set the hostname within the sandbox, defaults to the current hostname

- `verbose`: Set whether the sandbox construction process should be more or less verbose.
"""
struct SandboxConfig
    read_only_maps::Dict{String,String}
    read_write_maps::Dict{String,String}
    env::Dict{String,String}
    entrypoint::Union{String,Nothing}
    pwd::String
    persist::Bool
    multiarch_formats::Vector{BinFmtRegistration}
    uid::Cint
    gid::Cint
    tmpfs_size::Union{String, Nothing}
    hostname::Union{String, Nothing}

    stdin::AnyRedirectable
    stdout::AnyRedirectable
    stderr::AnyRedirectable
    verbose::Bool

    function SandboxConfig(read_only_maps::Dict{String,String},
                           read_write_maps::Dict{String,String} = Dict{String,String}(),
                           env::Dict{String,String} = Dict{String,String}();
                           entrypoint::Union{String,Nothing} = nothing,
                           pwd::String = "/",
                           persist::Bool = true,
                           multiarch::Vector{<:Platform} = Platform[],
                           uid::Integer=0,
                           gid::Integer=0,
                           tmpfs_size::Union{String, Nothing}=nothing,
                           hostname::Union{String, Nothing}=nothing,
                           stdin::AnyRedirectable = Base.devnull,
                           stdout::AnyRedirectable = Base.stdout,
                           stderr::AnyRedirectable = Base.stderr,
                           verbose::Bool = false)
        # Lint the maps to ensure that all are absolute paths:
        for path in [keys(read_only_maps)..., values(read_only_maps)...,
                     keys(read_write_maps)..., values(read_write_maps)...,
                     something(entrypoint, "/"), pwd]
            if !startswith(path, "/")
                throw(ArgumentError("Path mapping $(path) is not absolute!"))
            end
        end

        # Force every path to be `realpath()`'ed
        for (dst, src) in read_only_maps
            read_only_maps[dst] = realpath(src)
        end
        for (dst, src) in read_write_maps
            read_write_maps[dst] = realpath(src)
        end

        for path in [values(read_only_maps)...; values(read_write_maps)...]
            crypt, mountpoint = is_ecryptfs(path; verbose)
            if crypt
                throw(ArgumentError("Path $(path) is mounted on the ecryptfs filesystem $(mountpoint)!"))
            end
        end

        # Ensure that read_only_maps contains a mapping for the root in the guest:
        if !haskey(read_only_maps, "/")
            throw(ArgumentError("Must provide a read-only root mapping!"))
        end

        # Collect all multiarch platforms, mapping to the known interpreter for that platform.
        multiarch_formats = Set{BinFmtRegistration}()
        interp_platforms = collect(keys(platform_qemu_registrations))
        for platform in multiarch
            # If this platform is natively runnable, skip it
            if natively_runnable(platform)
                continue
            end

            platform_idx = findfirst(p -> platforms_match(platform, p), interp_platforms)
            if platform_idx === nothing
                throw(ArgumentError("Platform $(triplet(platform)) unsupported for multiarch!"))
            end
            push!(multiarch_formats, platform_qemu_registrations[interp_platforms[platform_idx]])
        end

        return new(read_only_maps, read_write_maps, env, entrypoint, pwd, persist, collect(multiarch_formats), Cint(uid), Cint(gid), tmpfs_size, hostname, stdin, stdout, stderr, verbose)
    end
end
