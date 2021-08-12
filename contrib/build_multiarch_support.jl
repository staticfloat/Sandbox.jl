using Pkg, Pkg.Artifacts, SHA, Scratch

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

# Bind it into our Artifacts.toml
bind_artifact!(
    joinpath(@__DIR__, "..", "Artifacts.toml"),
    "multiarch-support",
    artifact_hash;
    force=true
)
