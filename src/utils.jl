"""
    max_directory_ctime(prefix::String)

Takes the `stat()` of all files in a directory root, keeping the maximum ctime,
recursively.  Comparing just this value allows for quick directory change detection.
"""
function max_directory_ctime(prefix::String)
    max_time = 0.0
    for (root, dirs, files) in walkdir(prefix)
        for f in files
            max_time = max(max_time, lstat(joinpath(root, f)).ctime)
        end
    end
    return max_time
end

"""
    is_ecryptfs(path::AbstractString; verbose::Bool=false)

Checks to see if the given `path` (or any parent directory) is placed upon an
`ecryptfs` mount.  This is known not to work on current kernels, see this bug
for more details: https://bugzilla.kernel.org/show_bug.cgi?id=197603

This method returns whether it is encrypted or not, and what mountpoint it used
to make that decision.
"""
function is_ecryptfs(path::AbstractString; verbose::Bool=false)
    # Canonicalize `path` immediately, and if it's a directory, add a "/" so
    # as to be consistent with the rest of this function
    path = abspath(path)
    if isdir(path)
        path = abspath(path * "/")
    end

    if verbose
        @info("Checking to see if $path is encrypted...")
    end

    # Get a listing of the current mounts.  If we can't do this, just give up
    if !isfile("/proc/mounts")
        if verbose
            @info("Couldn't open /proc/mounts, returning...")
        end
        return false, path
    end
    mounts = String(read("/proc/mounts"))

    # Grab the fstype and the mountpoints
    mounts = [split(m)[2:3] for m in split(mounts, "\n") if !isempty(m)]

    # Canonicalize mountpoints now so as to dodge symlink difficulties
    mounts = [(abspath(m[1]*"/"), m[2]) for m in mounts]

    # Fast-path asking for a mountpoint directly (e.g. not a subdirectory)
    direct_path = [m[1] == path for m in mounts]
    local parent
    if any(direct_path)
        parent = mounts[findfirst(direct_path)]
    else
        # Find the longest prefix mount:
        parent_mounts = [m for m in mounts if startswith(path, m[1])]
        if isempty(parent_mounts)
            # This is weird; this means that we can't find any mountpoints that
            # hold the given path.  I've only ever seen this in `chroot`'ed scenarios.
            return false, path
        end
        parent = parent_mounts[argmax(map(m->length(m[1]), parent_mounts))]
    end

    # Return true if this mountpoint is an ecryptfs mount
    val = parent[2] == "ecryptfs"
    if verbose && val
        @info("  -> $path is encrypted from mountpoint $(parent[1])")
    end
    return val, parent[1]
end

"""
    uname()

On Linux systems, return the strings returned by the `uname()` function in libc.
"""
function uname()
    if !Sys.islinux()
        return String[]
    end

    # Get libc (or musl) and handle to uname
    possible_libc_names = String["libc.so"]
    possible_musl_names = String["ld-musl-x86_64.so"]
    libcs = filter(x -> any(occursin.(possible_libc_names, Ref(x))), dllist())
    if isempty(libcs)
        @debug("Could not find libc, so will look for musl instead")
        libcs = filter(x -> any(occursin.(possible_musl_names, Ref(x))), dllist())
    end
    isempty(libcs) && error("Could not find libc or musl, unable to call uname()")
    libc = dlopen(first(libcs))
    uname_hdl = dlsym(libc, :uname)

    # The uname struct can have wildly differing layouts; we take advantage
    # of the fact that it is just a bunch of NULL-terminated strings laid out
    # one after the other, and that it is (as best as I can tell) at maximum
    # around 1.5KB long.  We bump up to 2KB to be safe.
    uname_struct = zeros(UInt8, 2048)
    ccall(uname_hdl, Cint, (Ptr{UInt8},), uname_struct)

    # Parse out all the strings embedded within this struct
    strings = String[]
    idx = 1
    while idx < length(uname_struct)
        # Extract string
        new_string = unsafe_string(pointer(uname_struct, idx))
        push!(strings, new_string)
        idx += length(new_string) + 1

        # Skip trailing zeros
        while uname_struct[idx] == 0 && idx < length(uname_struct)
            idx += 1
        end
    end

    return strings
end

"""
    get_kernel_version(;verbose::Bool = false)

Use `uname()` to get the kernel version and parse it out as a `VersionNumber`,
returning `nothing` if parsing fails or this is not `Linux`.
"""
function get_kernel_version(;verbose::Bool = false)
    if !Sys.islinux()
        return nothing
    end

    uname_strings = try
        uname()
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end

        @warn("Unable to run `uname()` to check version number!")
        return nothing
    end

    # Some distributions tack extra stuff onto the version number.  We walk backwards
    # from the end, searching for the longest string that we can extract a VersionNumber
    # out of.  We choose a minimum length of 5, as all kernel version numbers will be at
    # least `X.Y.Z`.
    for end_idx in length(uname_strings[3]):-1:5
        try
            return VersionNumber(uname_strings[3][1:end_idx])
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
        end
    end

    # We could never parse anything good out of it. :(
    if verbose
        @warn("Unablet to parse a VersionNumber out of uname output", uname_strings)
    end
    return nothing
end

"""
    getuid()

Wrapper around libc's `getuid()` function
"""
getuid() = ccall(:getuid, Cint, ())

"""
    getgid()

Wrapper around libc's `getuid()` function
"""
getgid() = ccall(:getgid, Cint, ())

_sudo_cmd = nothing
function sudo_cmd()
    global _sudo_cmd

    # Use cached value if we've already run this
    if _sudo_cmd !== nothing
        return _sudo_cmd
    end

    if getuid() == 0
        # If we're already root, don't use any kind of sudo program
        _sudo_cmd = String[]
    elseif Sys.which("sudo") !== nothing success(`sudo -V`)
        # If `sudo` is available, use that
        _sudo_cmd = ["sudo"]
    elseif Sys.which("su") !== nothing
        # Fall back to `su` if all else fails
        _sudo_cmd = ["su", "root", "-c"]
    else
        @warn("No known sudo-like wrappers!")
        _sudo_cmd = String[]
    end
    return _sudo_cmd
end
