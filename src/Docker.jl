using Random, Tar
import Tar_jll

Base.@kwdef struct DockerExecutor <: SandboxExecutor
    label::String = Random.randstring(10)
    privileges::Symbol = :privileged
end

function cleanup(exe::DockerExecutor)
    success(`docker system prune --force --filter=label=$(docker_image_label(exe))`)
end

Base.show(io::IO, exe::DockerExecutor) = write(io, "Docker Executor")

function executor_available(::Type{DockerExecutor}; verbose::Bool = false)
    # don't even try to exec if it doesn't exist
    if Sys.which("docker") === nothing
        if verbose
            @info("No `docker` command found; docker unavailable")
        end
        return false
    end

    # Return true if we can `docker ps`; if we can't, then there's probably a permissions issue
    if !success(`docker ps`)
        if verbose
            @warn("Unable to run `docker ps`; perhaps you're not in the `docker` group?")
        end
        return false
    end
    return with_executor(DockerExecutor) do exe
        return probe_executor(exe; test_read_only_map=true, test_read_write_map=true, verbose)
    end
end

timestamps_path() = joinpath(@get_scratch!("docker_timestamp_hashes"), "path_timestamps.toml")
function load_timestamps()
    path = timestamps_path()
    if !isfile(path)
        return Dict()
    end
    try
        return TOML.parsefile(path)
    catch e
        @error("couldn't load $(path)", exception=e)
        return Dict()
    end
end

function save_timestamp(image_name::String, timestamp::Float64)
    timestamps_toml = entry = sprint() do io
        timestamps = load_timestamps()
        timestamps[image_name] = timestamp
        TOML.print(io, timestamps)
    end
    open(timestamps_path(), write=true) do io
        write(io, timestamps_toml)
    end
end

docker_image_name(root_path::String, uid::Cint, gid::Cint) = "sandbox_rootfs:$(string(Base._crc32c(root_path), base=16))-$(uid)-$(gid)"
docker_image_label(exe::DockerExecutor) = string("org.julialang.sandbox.jl=", exe.label)
function should_build_docker_image(root_path::String, uid::Cint, gid::Cint)
    # If the image doesn't exist at all, always return true
    image_name = docker_image_name(root_path, uid, gid)
    if !success(`docker image inspect $(image_name)`)
        return true
    end

    # If this image has been built before, compare its historical timestamp to the current one
    curr_ctime = max_directory_ctime(root_path)
    prev_ctime = get(load_timestamps(), image_name, 0.0)
    return curr_ctime != prev_ctime
end

"""
    build_docker_image(root_path::String)

Docker doesn't like volume mounts within volume mounts, like we do with `sandbox`.
So we do things "the docker way", where we construct a rootfs docker image, then mount
things on top of that, with no recursive mounting.  We cut down on unnecessary work
somewhat by quick-scanning the directory for changes and only rebuilding if changes
are detected.
"""
function build_docker_image(root_path::String, uid::Cint, gid::Cint; verbose::Bool = false)
    image_name = docker_image_name(root_path, uid, gid)
    if should_build_docker_image(root_path, uid, gid)
        max_ctime = max_directory_ctime(root_path)
        if verbose
            @info("Building docker image $(image_name) with max timestamp $(max_ctime)")
        end

        # Build the docker image
        open(`docker import - $(image_name)`, "w", verbose ? stdout : devnull) do io
            # We need to record permissions, and therefore we cannot use Tar.jl.
            # Some systems (e.g. macOS) ship with a BSD tar that does not support the
            # `--owner` and `--group` command-line options. Therefore, if Tar_jll is
            # available, we use the GNU tar provided by Tar_jll. If Tar_jll is not available,
            # we fall back to the system tar.
            cd(root_path) do
                tar = Tar_jll.is_available() ? Tar_jll.tar() : `tar`
                run(pipeline(`$(tar) -c --owner=$(uid) --group=$(gid) .`, stdout=io))
            end
        end

        # Record that we built it
        save_timestamp(image_name, max_ctime)
    end

    return image_name
end

function commit_previous_run(exe::DockerExecutor, image_name::String)
    ids = split(readchomp(`docker ps -a --filter label=$(docker_image_label(exe)) --format "{{.ID}}"`))
    if isempty(ids)
        return image_name
    end

    # We'll take the first docker container ID that we get, as its the most recent, and commit it.
    image_name = "sandbox_rootfs_persist:$(first(ids))"
    run(`docker commit $(first(ids)) $(image_name)`)
    return image_name
end

function build_executor_command(exe::DockerExecutor, config::SandboxConfig, user_cmd::Cmd)
    # Build the docker image that corresponds to this rootfs
    image_name = build_docker_image(config.read_only_maps["/"], config.uid, config.gid; verbose=config.verbose)

    if config.persist
        # If this is a persistent run, check to see if any previous runs have happened from
        # this executor, and if they have, we'll commit that previous run as a new image and
        # use it instead of the "base" image.
        image_name = commit_previous_run(exe, image_name)
    end

    # Begin building `docker` args
    if exe.privileges === :privileged  # this is the default
        # pros: allows you to do nested execution. e.g. the ability to run `Sandbox` inside `Sandbox`
        # cons: may allow processes inside the Docker container to access secure environment variables of processes outside the container
        privilege_args = String["--privileged"]
    elseif exe.privileges === :no_new_privileges
        # pros: may prevent privilege escalation attempts
        # cons: you won't be able to do nested execution
        privilege_args = String["--security-opt", "no-new-privileges"]
    elseif exe.privileges === :unprivileged
        # cons: you won't be able to do nested execution; privilege escalation may still work
        privilege_args = String[]
    else
        throw(ArgumentError("invalid value for exe.privileges: $(exe.privileges)"))
    end
    cmd_string = String["docker", "run", privilege_args..., "-i", "--label", docker_image_label(exe)]

    # If we're doing a fully-interactive session, tell it to allocate a psuedo-TTY
    if all(isa.((config.stdin, config.stdout, config.stderr), Base.TTY))
        push!(cmd_string, "-t")
    end

    # Start in the right directory
    append!(cmd_string, ["-w", config.pwd])

    # Add in read-only mappings (skipping the rootfs)
    for (dst, src) in config.read_only_maps
        if dst == "/"
            continue
        end
        append!(cmd_string, ["-v", "$(src):$(dst):ro"])
    end

    # Add in read-write mappings
    for (dst, src) in config.read_write_maps
        append!(cmd_string, ["-v", "$(src):$(dst)"])
    end

    # Apply environment mappings, first from `config`, next from `user_cmd`.
    for (k, v) in config.env
        append!(cmd_string, ["-e", "$(k)=$(v)"])
    end
    if user_cmd.env !== nothing
        for pair in user_cmd.env
            append!(cmd_string, ["-e", pair])
        end
    end

    # Add in entrypoint, if it is set
    if config.entrypoint !== nothing
        append!(cmd_string, ["--entrypoint", config.entrypoint])
    end

    if config.hostname !== nothing
        append!(cmd_string, ["--hostname", config.hostname])
    end

    # For each platform requested by `multiarch`, ensure its matching interpreter is registered,
    # but only if we're on Linux.  If we're on some other platform, like macOS where Docker is
    # implemented with a virtual machine, we just trust the docker folks to have set up the
    # relevant `binfmt_misc` mappings properly.
    if Sys.islinux()
        register_requested_formats!(config.multiarch_formats; verbose=config.verbose)
    end

    # Set the user and group
    append!(cmd_string, ["--user", "$(config.uid):$(config.gid)"])

    # Finally, append the docker image name user-requested command string
    push!(cmd_string, image_name)
    append!(cmd_string, user_cmd.exec)

    docker_cmd = Cmd(cmd_string)

    # If the user has asked that this command be allowed to fail silently, pass that on
    if user_cmd.ignorestatus
        docker_cmd = ignorestatus(docker_cmd)
    end

    return docker_cmd
end

sanitize_key(name) = replace(name, ':' => '-')

"""
    export_docker_image(image::String,
                        output_dir::String = <default scratch location>;
                        verbose::Bool = false,
                        force::Bool = false)

Exports the given docker image name to the requested output directory.  Useful
for pulling down a known good rootfs image from Docker Hub, for future use by
Sandbox executors.  If `force` is set to true, will overwrite a pre-existing
directory, otherwise will silently return.
"""
function export_docker_image(image_name::String,
                             output_dir::String = @get_scratch!("docker-$(sanitize_key(image_name))");
                             force::Bool = false,
                             verbose::Bool = false)
    if ispath(output_dir) && !isempty(readdir(output_dir))
        if force
            rmdir(output_dir; force=true, recursive=true)
        else
            if verbose
                @warn("Will not overwrite pre-existing directory $(output_dir)")
            end
            return output_dir
        end
    end

    # Get a container ID ready to be passed to `docker export`
    container_id = readchomp(`docker create $(image_name) /bin/true`)

    # Get the ID of that container (since we can't export by label, sadly)
    if isempty(container_id)
        if verbose
            @warn("Unable to create conatiner based on $(image_name)")
        end
        return nothing
    end

    # Export the container filesystem to a directory
    try
        mkpath(output_dir)
        open(`docker export $(container_id)`) do tar_io
            Tar.extract(tar_io, output_dir) do hdr
                # Skip known troublesome files
                return hdr.type ∉ (:chardev,)
            end
        end
    finally
        run(`docker rm -f $(container_id)`)
    end
    return output_dir
end

"""
    pull_docker_image(image::String,
                      output_dir::String = <default scratch location>;
                      platform::String = "",
                      verbose::Bool = false,
                      force::Bool = false)

Pulls and saves the given docker image name to the requested output directory.
Useful for pulling down a known good rootfs image from Docker Hub, for future use
by Sandbox executors.  If `force` is set to true, will overwrite a pre-existing
directory, otherwise will silently return.  Optionally specify the platform of the
image with `platform`.
"""
function pull_docker_image(image_name::String,
                           output_dir::String = @get_scratch!("docker-$(sanitize_key(image_name))");
                           platform::String = "",
                           force::Bool = false,
                           verbose::Bool = false)
    if ispath(output_dir) && !isempty(readdir(output_dir))
        if force
            rmdir(output_dir; force=true, recursive=true)
        else
            if verbose
                @warn("Will not overwrite pre-existing directory $(output_dir)")
            end
            return output_dir
        end
    end

    # Pull the latest version of the image
    try
        p = isempty(platform) ? `` : `--platform $(platform)`
        run(`docker pull $(p) $(image_name)`)
    catch
        if verbose
            @warn("Cannot pull", image_name)
        end
        return nothing
    end

    # Once the image is pulled, export it to given output directory
    return export_docker_image(image_name, output_dir; force, verbose)
end
