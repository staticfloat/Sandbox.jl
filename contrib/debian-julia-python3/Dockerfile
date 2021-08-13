# This is an example of how to create a rootfs image from a Dockerfile
# Build this with `julia --project contrib/build_docker_images.jl debian-julia-python3`
ARG JULIA_VERSION=1.6
FROM julia:${JULIA_VERSION} as julia_container

# Our base image will be debian
FROM debian

# Copy julia over from the `julia` container
COPY --from=julia_container /usr/local/julia /usr/local/julia
RUN ln -s /usr/local/julia/bin/julia /usr/local/bin/julia

# Install some useful tools
RUN apt update && apt install -y curl python3
