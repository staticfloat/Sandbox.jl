# This is an example of how to build a very multi-arch container that can run simple C programs.
# Build this with `julia --project contrib/build_docker_images.jl multiarch`


# Get ourselves a bunch of architectures, which we'll copy libraries from
FROM multiarch/ubuntu-core:arm64-bionic   AS aarch64-linux-gnu
FROM multiarch/ubuntu-core:armhf-bionic   AS armv7l-linux-gnueabihf
FROM multiarch/ubuntu-core:ppc64el-bionic AS powerpc64le-linux-gnu
FROM multiarch/ubuntu-core:i386-bionic    AS i686-linux-gnu
FROM multiarch/ubuntu-core:x86_64-bionic  AS x86_64-linux-gnu
FROM multiarch/alpine:aarch64-v3.14       AS aarch64-linux-musl
FROM multiarch/alpine:armhf-v3.14         AS armv7l-linux-musleabihf
FROM multiarch/alpine:ppc64le-v3.14       AS powerpc64le-linux-musl
FROM multiarch/alpine:i386-v3.14          AS i686-linux-musl
# This will be our "default" image, so we won't copy from it.
FROM multiarch/alpine:x86_64-v3.14        AS x86_64-linux-musl

# Install loaders
COPY --from=aarch64-linux-gnu       /lib/ld-linux-aarch64.so.1    /lib/
COPY --from=armv7l-linux-gnueabihf  /lib/ld-linux-armhf.so.3      /lib/
COPY --from=powerpc64le-linux-gnu   /lib64/ld64.so.2              /lib64/
COPY --from=i686-linux-gnu          /lib/ld-linux.so.2            /lib/
COPY --from=x86_64-linux-gnu        /lib64/ld-linux-x86-64.so.2   /lib64/
COPY --from=aarch64-linux-musl      /lib/ld-musl-aarch64.so.1     /lib/
COPY --from=armv7l-linux-musleabihf /lib/ld-musl-armhf.so.1       /lib/
COPY --from=powerpc64le-linux-musl  /lib/ld-musl-powerpc64le.so.1 /lib/
COPY --from=i686-linux-musl         /lib/ld-musl-i386.so.1        /lib/

# Install libc into `/lib/${target}`
COPY --from=aarch64-linux-gnu       /lib/aarch64-linux-gnu/libc*.so*     /lib/aarch64-linux-gnu/
COPY --from=armv7l-linux-gnueabihf  /lib/arm-linux-gnueabihf/libc*.so*   /lib/arm-linux-gnueabihf/
COPY --from=powerpc64le-linux-gnu   /lib/powerpc64le-linux-gnu/libc*.so* /lib/powerpc64le-linux-gnu/
COPY --from=i686-linux-gnu          /lib/i386-linux-gnu/libc*.so*        /lib/i386-linux-gnu/
COPY --from=x86_64-linux-gnu        /lib/x86_64-linux-gnu/libc*.so*      /lib/x86_64-linux-gnu/
COPY --from=aarch64-linux-musl      /lib/libc.musl-aarch64.so.1          /lib/
COPY --from=armv7l-linux-musleabihf /lib/libc.musl-armhf.so.1            /lib/
COPY --from=powerpc64le-linux-musl  /lib/libc.musl-ppc64le.so.1          /lib/
COPY --from=i686-linux-musl         /lib/libc.musl-x86.so.1              /lib/

# Cleanup some troublesome files
RUN rm -rf /bin/bbsuid
