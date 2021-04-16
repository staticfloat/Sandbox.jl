module Sandbox
using Preferences, Scratch, Artifacts, Tar, TOML, Libdl

import Base: run
export SandboxExecutor, DockerExecutor, UserNamespacesExecutor, SandboxConfig,
       preferred_executor, executor_available, probe_executor, run, cleanup, with_executor

# Include some utilities for things like file manipulation, uname() parsing, etc...
include("utils.jl")

"""
    SandboxExecutor

This represents the base type for all execution backends within this package.
Valid concrete subtypes must implement at least the following methods:

* `T()`: no-argument constructor to ready an execution engine with all defaults.

* `executor_available(::DataType{T})`: Checks whether executor type `T` is available
  on this system.  For example, `UserNamespacesExecutor`s are only available on
  Linux, and even then only on certain kernels.  Availablility checks may run a
  program to determine whether that executor is actually available.

* `build_executor_command(exe::T, config::SandboxConfig, cmd::Cmd)`: Builds the
  `Cmd` object that, when run, executes the user's desired command within the given
  sandbox.  The `config` object contains all necessary metadata such as shard
  mappings, environment variables, `stdin`/`stdout`/`stderr` redirection, etc...

* `cleanup(exe::T)`: Cleans up any persistent data storage that this executor may
  have built up over the course of its execution.

Note that while you can manually construct and cleanup an executor, it is recommended
that users instead make use of the `with_executor()` convenience function:

    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        run(exe, config, ...)
    end
"""
abstract type SandboxExecutor; end

include("SandboxConfig.jl")

# Load the Docker executor
include("Docker.jl")

# Load the UserNamespace executor
include("UserNamespaces.jl")

all_executors = Type{<:SandboxExecutor}[
    # We always prefer the UserNamespaces executor, if we can use it,
    # and the unprivileged one most of all.  Only after that do we try `docker`.
    UnprivilegedUserNamespacesExecutor,
    PrivilegedUserNamespacesExecutor,
    DockerExecutor,
]

function select_executor(verbose::Bool)
    # If we have a preference set, use that unconditionally.
    executor = @load_preference("executor")
    if executor !== nothing
        executor = lowercase(executor)
        if executor ∈ ("unprivilegedusernamespacesexecutor", "unprivileged", "userns")
            return UnprivilegedUserNamespacesExecutor
        elseif executor ∈ ("privilegedusernamespacesexecutor", "privileged")
            return PrivilegedUserNamespacesExecutor
        elseif executor ∈ ("dockerexecutor", "docker")
            return DockerExecutor
        end
    end

    # Otherwise, just try them in priority order
    for executor in all_executors
        if executor_available(executor; verbose)
            return executor
        end
    end
    error("Could not find any available executors!")
end

_preferred_executor = nothing
function preferred_executor(;verbose::Bool = false)
    # If we've already asked this question, return the old answer
    global _preferred_executor
    if _preferred_executor === nothing
        _preferred_executor = select_executor(verbose)
    end
    return _preferred_executor
end

# Helper function for warning about privileged execution trying to invoke `sudo`
prompted_userns_privileged = false
function warn_priviledged(::PrivilegedUserNamespacesExecutor)
    global prompted_userns_privileged
    if !prompted_userns_privileged
        @info("Running privileged container via `sudo`, may ask for your password:")
        prompted_userns_privileged = true
    end
end
warn_priviledged(::SandboxExecutor) = nothing

function run(exe::SandboxExecutor, config::SandboxConfig, user_cmd::Cmd; kwargs...)
    cmd = pipeline(build_executor_command(exe, config, user_cmd); config.stdin, config.stdout, config.stderr)
    if config.verbose
        @info("Running sandboxed command", user_cmd.exec)
    end
    warn_priviledged(exe)
    return run(cmd; kwargs...)
end

function with_executor(f::Function, executor_type::Type{<:SandboxExecutor} = preferred_executor())
    exe = executor_type()
    try
        return f(exe)
    finally
        cleanup(exe)
    end
end

function probe_executor(executor::SandboxExecutor; verbose::Bool = false, test_read_only_map=false, test_read_write_map=false)
    mktempdir() do tmpdir
        read_only_maps = Dict{String,String}(
            "/" => artifact"AlpineRootfs",
        )
        read_write_maps = Dict{String,String}()

        # The simplest test is to see if stdout capturing works
        inner_cmd = "echo 'hello julia'"

        # Test whether we can use read-only mappings
        if test_read_only_map
            map_dir = joinpath(tmpdir, "read_only_map")
            mkdir(map_dir)
            open(joinpath(map_dir, "foo"), write=true) do io
                write(io, "read-only mapping successful")
            end

            # Mount that directory in /read_only
            read_only_maps["/read_only"] = map_dir

            # Read from the foo file
            inner_cmd = "$(inner_cmd) && cat /read_only/foo"
        end

        # Test whether we can use read-write mappings
        if test_read_write_map
            workspace_dir = joinpath(tmpdir, "read_write_map")
            mkdir(workspace_dir)

            # Mount that directory in /read_write
            read_write_maps["/read_write"] = workspace_dir

            # Write to the foo file
            inner_cmd = "$(inner_cmd) && echo read-write mapping successful >> /read_write/foo"
        end

        cmd_stdout = IOBuffer()
        cmd_stderr = IOBuffer()
        config = SandboxConfig(
            read_only_maps,
            read_write_maps,
            Dict("PATH" => "/bin:/usr/bin");
            stdout=cmd_stdout,
            stderr=cmd_stderr,
        )
        user_cmd = `/bin/sh -c "$(inner_cmd)"`

        if verbose
            tests = String[]
            if test_read_only_map
                push!(tests, "read-only")
            end
            if test_read_write_map
                push!(tests, "read-write")
            end
            @info("Testing $(executor) ($(join(tests, ", ")))")
        end

        # Command should execute successfully
        user_cmd = ignorestatus(user_cmd)
        if !success(run(executor, config, user_cmd))
            if verbose
                cmd_stdout = String(take!(cmd_stdout))
                cmd_stderr = String(take!(cmd_stderr))
                @warn("Unable to run `sandbox` itself", cmd_stdout, cmd_stderr)
            end
            return false
        end

        # No stderr output (unless we're running in verbose mode)
        if !verbose
            stderr_output = String(take!(cmd_stderr))
            if !isempty(stderr_output)
                @warn(" -> Non-empty stderr output", stderr_output)
                return false
            end
        end

        # stdout shuold contain "hello julia" as its own line
        cmd_stdout = String(take!(cmd_stdout))
        stdout_lines = split(cmd_stdout, "\n")
        if !("hello julia" in stdout_lines)
            if verbose
                @warn(" -> Basic stdout sentinel missing!", stdout_lines)
            end
            return false
        end

        if test_read_only_map
            if !("read-only mapping successful" in stdout_lines)
                if verbose
                    @warn(" -> Read-only mapping sentinel missing!")
                end
                return false
            end
        end

        if test_read_write_map
            foo_file = joinpath(joinpath(tmpdir, "read_write_map", "foo"))
            if !isfile(foo_file)
                if verbose
                    @warn(" -> Read-write mapping sentinel file missing!")
                end
                return false
            end

            foo_file_contents = String(read(foo_file))
            if foo_file_contents != "read-write mapping successful\n"
                if verbose
                    @warn(" -> Read-write mapping data corrupted", foo_file_contents)
                end
                return false
            end
        end
        return true
    end
end

# Convenience function for other users who want to do some testing
alpine_rootfs() = artifact"AlpineRootfs"

end # module
