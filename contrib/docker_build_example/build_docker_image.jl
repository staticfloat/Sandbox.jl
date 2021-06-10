#!/usr/bin/env julia

using Sandbox, Pkg.Artifacts, Scratch, SHA, ghr_jll

image_name = "debian-julia-python3"
run(`docker build -t $(image_name) $(@__DIR__)`)

artifact_hash = create_artifact() do dir
    @info("Building $(image_name)")
    Sandbox.export_docker_image(image_name, dir; verbose=true)
    @info("Hashing")
end

# Write out to a file
tarball_path = joinpath(@get_scratch!("archived"), "julia-python3.tar.gz")
@info("Archiving out to $(tarball_path)")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload to `staticfloat/Sandbox.jl`, create a tag based on this docker image
tag_name = "$(image_name)-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to staticfloat/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)

# Bind it into `Artifacts.toml`
tarball_url = "https://github.com/staticfloat/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"
bind_artifact!(
    joinpath(dirname(dirname(@__DIR__)), "Artifacts.toml"),
    "$(image_name)-rootfs",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    lazy=true,
    force=true,
)
