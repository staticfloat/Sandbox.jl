#!/usr/bin/env julia

using Sandbox, Pkg, Pkg.Artifacts, Scratch
using ghr_jll, SHA

docker_image = "julia:alpine"

artifact_hash = create_artifact() do dir
    @info("Pulling $(docker_image)")
    Sandbox.pull_docker_image(docker_image, dir; verbose=true)
    @info("Hashing")
end

# Write out to a file
tarball_path = joinpath(@get_scratch!("archived"), "julia_alpine.tar.gz")
@info("Archiving out to $(tarball_path)")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload to `staticfloat/Sandbox.jl`, create a tag based on this docker image
docker_image_dash = replace(docker_image, ":" => "-")
tag_name = "$(docker_image_dash)-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to staticfloat/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)

# Bind it into `Artifacts.toml`
tarball_url = "https://github.com/staticfloat/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"
bind_artifact!(
    joinpath(dirname(@__DIR__), "Artifacts.toml"),
    "$(docker_image_dash)-rootfs",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    lazy=true,
)