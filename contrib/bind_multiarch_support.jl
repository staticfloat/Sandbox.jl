using Pkg, Downloads, TreeArchival, SHA, Base.BinaryPlatforms

root_url = "https://github.com/dbhi/qus/releases/download/v0.0.11-v7.1%2Bdfsg-2--bpo11%2B3"

qemu_host_maps = (
    "x86_64" => "amd64",
    "aarch64" => "arm64v8",
    "armv7l" => "arm32v7",
    "ppc64le" => "ppc64le",
)
qemu_target_arch_list = [
    "x86_64",
    "i386",
    "aarch64",
    "arm",
    "ppc64le",
]

for (host_arch, tarball_arch) in qemu_host_maps
    for target_arch in qemu_target_arch_list
        # First, download the tarball
        mktempdir() do dir
            url = "$(root_url)/qemu-$(target_arch)-static_$(tarball_arch).tgz"
            file_path = joinpath(dir, basename(url))
            Downloads.download(url, file_path)

            # Get the tarball and tree hashes
            tarball_hash = bytes2hex(open(SHA.sha256, file_path))
            tree_hash = Base.SHA1(TreeArchival.treehash(file_path))

            artifacts_toml = Pkg.Artifacts.find_artifacts_toml(dirname(@__DIR__))

            # Because this is technically a static executable, we drop the implicit `libc` constraint
            # so that it matches both `glibc` and `musl` hosts:
            host_platform = Platform(host_arch, "linux")
            delete!(tags(host_platform), "libc")
            Pkg.Artifacts.bind_artifact!(
                artifacts_toml,
                "qemu-$(target_arch)",
                tree_hash;
                platform=host_platform,
                download_info=[(url, tarball_hash)],
                lazy=true,
                force=true,
            )
        end
    end
end

