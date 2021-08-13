using Pkg, Pkg.Artifacts, SHA, Scratch, ghr_jll, Base.BinaryPlatforms

# We'll download and install `qemu-static` into an artifact for easy mounting
qemu_static_tag = "v6.0.0-2"
qemu_static_url = "https://github.com/multiarch/qemu-user-static/releases/download/$(qemu_static_tag)"
qemu_host_arch_list = (
    "x86_64",
)
qemu_target_arch_list = (
    "x86_64",
    "i386",
    "aarch64",
    "arm",
    "ppc64le",
)

@info("Creating multiarch support tarball")
artifact_hash = create_artifact() do artifact_dir
    # Download QEMU static builds
    for host_arch in qemu_host_arch_list
        for target_arch in qemu_target_arch_list
            url = "$(qemu_static_url)/$(host_arch)_qemu-$(target_arch)-static.tar.gz"
            mktempdir() do unpack_dir
                rm(unpack_dir)
                Pkg.PlatformEngines.download_verify_unpack(url, nothing, unpack_dir)
                for f in readdir(unpack_dir; join=true)
                    mv(f, joinpath(artifact_dir, basename(f)))
                end
            end
        end
    end
end

@info("Archiving")
tarball_path = joinpath(@get_scratch!("archived"), "multiarch-support.tar.gz")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload it to `staticfloat/Sandbox.jl`
tag_name = "multiarch-support-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to staticfloat/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)
tarball_url = "https://github.com/staticfloat/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"

# Bind it into our Artifacts.toml (advertising support for both glibc and musl)
for libc in ("glibc", "musl")
    bind_artifact!(
        joinpath(@__DIR__, "..", "Artifacts.toml"),
        "multiarch-support",
        artifact_hash;
        download_info=[(tarball_url, tarball_hash)],
        platform = Platform("x86_64", "linux"; libc="glibc"),
        force=true,
        lazy=true,
    )
end

# Eventually, we hope to be able to build this for other host architectures as well!


## Also, download and create our `multiarch-testing` artifact, which contains HelloWorldC_jll for all our architectures.
HWC_version = v"1.1.2+0"
HWC_platforms = (
    Platform("x86_64", "linux"; libc="glibc"),
    Platform("x86_64", "linux"; libc="musl"),
    Platform("i686", "linux"; libc="glibc"),
    Platform("i686", "linux"; libc="musl"),
    Platform("aarch64", "linux"; libc="glibc"),
    Platform("aarch64", "linux"; libc="musl"),
    Platform("armv7l", "linux"; libc="glibc"),
    Platform("armv7l", "linux"; libc="musl"),
    Platform("powerpc64le", "linux"; libc="glibc"),
    # We don't have this one yet
    #Platform("powerpc64le", "linux"; libc="musl"),
)

artifact_hash = create_artifact() do dir
    for platform in HWC_platforms
        triplet = Base.BinaryPlatforms.triplet(platform)
        url = "https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl/releases/download/HelloWorldC-v$(HWC_version)/HelloWorldC.v$(HWC_version.major).$(HWC_version.minor).$(HWC_version.patch).$(triplet).tar.gz"
        mktempdir() do temp_dir
            rm(temp_dir)
            Pkg.PlatformEngines.download_verify_unpack(url, nothing, temp_dir)
            try
                mv(joinpath(temp_dir, "bin", "hello_world"), joinpath(dir, "hello_world.$(triplet)"))
            catch
            end
        end
    end
end

@info("Archiving")
tarball_path = joinpath(@get_scratch!("archived"), "multiarch-testing.tar.gz")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload it to `staticfloat/Sandbox.jl`
tag_name = "multiarch-testing-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to staticfloat/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)
tarball_url = "https://github.com/staticfloat/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"

# Bind it into our Artifacts.toml (advertising support for both glibc and musl)
bind_artifact!(
    joinpath(@__DIR__, "..", "Artifacts.toml"),
    "multiarch-testing",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    force=true,
    lazy=true,
)
