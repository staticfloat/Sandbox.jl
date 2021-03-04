using Random

mutable struct DockerExecutor <: SandboxExecutor
    label::String
    DockerExecutor() = new(Random.randstring(10))
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

docker_image_name(root_path::String) = "sandbox_rootfs:$(string(Base._crc32c(root_path), base=16))"
docker_image_label(exe::DockerExecutor) = string("org.julialang.sandbox.jl=", exe.label)
function should_build_docker_image(root_path::String)
    # If the image doesn't exist at all, always return true
    image_name = docker_image_name(root_path)
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
function build_docker_image(root_path::String; verbose::Bool = false)
    image_name = docker_image_name(root_path)
    if should_build_docker_image(root_path)
        max_ctime = max_directory_ctime(root_path)
        if verbose
            @info("Building docker image $(image_name) with max timestamp $(max_ctime)")
        end

        # Build the docker image
        open(`docker import - $(image_name)`, "w", verbose ? stdout : devnull) do io
            Tar.create(root_path, io)
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
    image_name = build_docker_image(config.read_only_maps["/"]; verbose=config.verbose)

    if config.persist
        # If this is a persistent run, check to see if any previous runs have happened from
        # this executor, and if they have, we'll commit that previous run as a new image and
        # use it instead of the "base" image.
        image_name = commit_previous_run(exe, image_name)
    end

    # Begin building `docker` args
    cmd_string = String["docker", "run", "--privileged", "-i", "--label", docker_image_label(exe)]

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
