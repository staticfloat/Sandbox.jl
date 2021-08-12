using Base.BinaryPlatforms

"""
    check_binfmt_misc_loaded()

Check that the `binfmt_misc` kernel module is loaded and enabled.
"""
function check_binfmt_misc_loaded()
    # If we're not running on Linux, just always return `false`
    if !Sys.islinux()
        return false
    end

    # If the `binfmt_misc` directory doesn't exist, the kernel module is likely not installed
    if !isdir("/proc/sys/fs/binfmt_misc")
        return false
    end

    # If the `status` file does not exist, the kernel module may not be loaded, or the
    # special `binfmt_misc` filesystem may not be mounted.
    if !isfile("/proc/sys/fs/binfmt_misc/status")
        return false
    end

    # Finally, check that the module itself has not been disabled.
    return true
    #return strip(String(read("/proc/sys/fs/binfmt_misc/status"))) == "enabled"
end

"""
    BinFmtRegistration

Provides a structured view of a `binfmt_misc` interpreter registration.  Note that only "magic"
matching rules are allowed, we do not support "extension" matching rules.
"""
struct BinFmtRegistration
    name::String
    interpreter::String
    flags::Vector{Symbol}
    offset::Int64
    magic::Vector{UInt8}
    mask::Vector{UInt8}

    function BinFmtRegistration(name::AbstractString,
                                interpreter::AbstractString,
                                flags::Union{AbstractString,Vector{Symbol}},
                                offset::Integer,
                                magic::Vector{UInt8},
                                mask::Union{Nothing,Vector{UInt8}} = nothing)
        # Default mask is all `0xff`.
        if mask === nothing
            mask = UInt8[0xff for _ in 1:length(magic)]
        end
        if isa(flags, AbstractString)
            flags = Symbol.(collect(flags))
        end
        return new(String(name), String(interpreter), sort(flags), Int64(offset), magic, mask)
    end
end

"""
    register_string(reg::BinFmtRegistration)

Constructs the string used to register a `binfmt_misc` registration with the `register`
file endpoint within `/proc/sys/fs/binfmt_misc/register`.  To actually register the
interpreter, use `write_binfmt_misc_registration()`.
"""
function register_string(reg::BinFmtRegistration)
    return string(
        ":",
        reg.name,
        ":",
        # We only support `magic` style registrations
        "M",
        ":",
        string(reg.offset),
        ":",
        # We need to actually emit double-escaped hex codes, since that's what `/register` expects.
        join([string("\\x", string(x, base=16, pad=2)) for x in reg.magic], ""),
        ":",
        join([string("\\x", string(x, base=16, pad=2)) for x in reg.mask], ""),
        ":",
        reg.interpreter,
        ":",
        join(String.(reg.flags), ""),
    )
end

macro check_specified(name)
    return quote
        if $(esc(name)) === nothing
            throw(ArgumentError($("Error, $(name) must be specified")))
        end
    end
end

"""
    BinFmtRegistration(file::String)

Reads a `binfmt_misc` registration in from disk, if it cannot be parsed (because it is
malformed, or uses unsupported features) it an `ArgumentError` will be thrown.
"""
function BinFmtRegistration(file::String)
    enabled = false
    interpreter = nothing
    flags = nothing
    offset = nothing
    magic = nothing
    mask = nothing
    for l in strip.(filter(!isempty, split(String(read(file)), "\n")))
        # Handle enabled/disabled line
        if l in ("enabled", "disabled")
            enabled = l == "enabled"
        elseif startswith(l, "interpreter ")
            interpreter = l[13:end]
        elseif startswith(l, "flags:")
            flags = l[8:end]
        elseif startswith(l, "offset ")
            offset = parse(Int64, l[8:end])
        elseif startswith(l, "magic ")
            magic = hex2bytes(l[7:end])
        elseif startswith(l, "mask ")
            mask = hex2bytes(l[6:end])
        else
            @warn("Unknown `binfmt_misc` configuration directive", line=l)
        end
    end

    # Ensure we are only dealing with properly fully-specified binfmt_misc registrations
    @check_specified interpreter
    @check_specified flags
    @check_specified offset
    @check_specified magic

    # If we found a disabled binfmt_misc registration, just ignore it
    if !enabled
        return nothing
    end
    
    return BinFmtRegistration(basename(file), interpreter, flags, offset, magic, mask)
end

function formats_match(a::BinFmtRegistration, b::BinFmtRegistration)
    return (a.magic .& a.mask) == (b.magic .& b.mask)
end


"""
    read_binfmt_misc_registrations()

Return a list of `BinFmtRegistration` objects, one per readable registration, as found
sitting in `/proc/sys/fs/binfmt_misc/*`.  Registrations that cannot be parsed are
silently ignored.
"""
function read_binfmt_misc_registrations()
    if !check_binfmt_misc_loaded()
        return String[]
    end

    registrations = BinFmtRegistration[]
    for f in readdir("/proc/sys/fs/binfmt_misc"; join=true)
        # Skip "special" files
        if basename(f) ∈ ("register", "status")
            continue
        end

        try
            reg = BinFmtRegistration(f)
            if reg !== nothing
                push!(registrations, reg)
            end
        catch e
            if isa(e, ArgumentError)
                continue
            end
            rethrow(e)
        end
    end
    return registrations
end

"""
    write_binfmt_misc_registration(reg::BinFmtRegistration)

Write a `binfmt_misc` registration out to the kernel's `register` file endpoint.
Requires `sudo` privileges.
"""
function write_binfmt_misc_registration(reg::BinFmtRegistration)
    try
        open(`$(sudo_cmd()) tee -a /proc/sys/fs/binfmt_misc/register`, write=true) do io
            write(io, register_string(reg))
        end
    catch e
        @error("Unable to register binfmt_misc format", register_string=register_string(reg))
        rethrow(e)
    end
end

function clear_binfmt_misc_registrations()
    open(`$(sudo_cmd()) tee -a /proc/sys/fs/binfmt_misc/status`, write=true) do io
        write(io, "-1")
    end
    return nothing
end

const platform_qemu_registrations = Dict(
    Platform("aarch64", "linux") => BinFmtRegistration(
        "qemu-aarch64",
        "/usr/bin/qemu-aarch64-static",
        "FC",
        0,
        UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0xb7, 0x00],
        UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
    ),
    Platform("armv7l", "linux") => BinFmtRegistration(
        "qemu-arm",
        "/usr/bin/qemu-arm-static",
        "FC",
        0,
        UInt8[0x7f, 0x45, 0x4c, 0x46, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x28, 0x00],
        UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
    ),
    Platform("ppc64le", "linux") => BinFmtRegistration(
        "qemu-ppc64le",
        # This is just a 
        "/usr/bin/qemu-ppc64le-static",
        "FC",
        0,
        UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x15, 0x00],
        UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfc, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0x00],
    ),
)
