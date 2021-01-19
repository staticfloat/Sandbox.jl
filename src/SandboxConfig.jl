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

- `pwd`: Set the working directory of the command that will be run.
  - This is a path within the sandbox, and must be absolute.

- `stdin`, `stdout`, `stderr`: input/output streams for the sandboxed process.
  - Can be any kind of `IO`, `TTY`, `devnull`, etc...

- `verbose`: Set whether the sandbox construction process should be more or less verbose.
"""
struct SandboxConfig
    read_only_maps::Dict{String,String}
    read_write_maps::Dict{String,String}
    env::Dict{String,String}
    pwd::String

    stdin::AnyRedirectable
    stdout::AnyRedirectable
    stderr::AnyRedirectable
    verbose::Bool

    function SandboxConfig(read_only_maps::Dict{String,String},
                           read_write_maps::Dict{String,String} = Dict{String,String}(),
                           env::Dict{String,String} = Dict{String,String}();
                           pwd::String = "/",
                           stdin::AnyRedirectable = Base.devnull,
                           stdout::AnyRedirectable = Base.stdout,
                           stderr::AnyRedirectable = Base.stderr,
                           verbose::Bool = false)
        # Lint the maps to ensure that all are absolute paths:
        for path in [keys(read_only_maps)..., values(read_only_maps)...,
                     keys(read_write_maps)..., values(read_write_maps)..., pwd]
            if !startswith(path, "/")
                throw(ArgumentError("Path mapping $(path) is not absolute!"))
            end
        end

        # Don't touch anything that is encrypted; it doesn't play well with user namespaces or docker
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
        return new(read_only_maps, read_write_maps, env, pwd, stdin, stdout, stderr, verbose)
    end
end