# =============================================================================
#  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
# ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
# ██║  ███╗███████║██║   ██║███████╗   ██║
# ██║   ██║██╔══██║██║   ██║╚════██║   ██║
# ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
#  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
# Handheld Security and Signal Terminal
# Build Container — Ubuntu 24.04 x86_64
# =============================================================================

# Ubuntu 24.04 build environment pinned to the locally cached digest to avoid
# unnecessary registry lookups on rebuild when Docker Hub DNS is flaky.
FROM ubuntu@sha256:d1e2e92c075e5ca139d51a140fff46f84315c0fdce203eab2807c7e495eff4f9

LABEL maintainer="ghOSt"
LABEL description="ghOSt build environment for Anbernic RG35XXH"
LABEL version="1.0.0"

# Prevent interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# =============================================================================
# INSTALL ALL BUILD DEPENDENCIES
# =============================================================================
RUN echo 'Acquire::Retries "10";' > /etc/apt/apt.conf.d/80retries \
    && echo 'Acquire::http::Timeout "120";' >> /etc/apt/apt.conf.d/80retries \
    && (sed -i 's|http://archive.ubuntu.com|http://us.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || sed -i 's|http://archive.ubuntu.com|http://us.archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null || true) \
    && for i in 1 2 3 4 5; do apt-get update --fix-missing && break || sleep 20; done \
    && apt-get install -y --no-install-recommends \
    # Core build tools
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    ninja-build \
    pkg-config \
    # ARM64 cross compiler
    crossbuild-essential-arm64 \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    crossbuild-essential-armel \
    gcc-arm-linux-gnueabi \
    g++-arm-linux-gnueabi \
    binutils-arm-linux-gnueabi \
    # Kernel build dependencies
    flex \
    bison \
    bc \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    lzop \
    u-boot-tools \
    device-tree-compiler \
    swig \
    python3-dev \
    # QEMU for ARM64 chroot
    qemu-user-static \
    binfmt-support \
    # Debootstrap
    debootstrap \
    # Image assembly tools
    parted \
    kpartx \
    dosfstools \
    e2fsprogs \
    # Download tools
    wget \
    curl \
    git \
    ca-certificates \
    gnupg2 \
    debian-archive-keyring \
    # Archive tools
    zip \
    unzip \
    xz-utils \
    lz4 \
    zstd \
    p7zip-full \
    # Filesystem tools
    rsync \
    pv \
    # Python
    python3 \
    python3-pip \
    # Utilities
    util-linux \
    fdisk \
    gdisk \
    coreutils \
    procps \
    # Cleanup
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# REGISTER ARM64 BINFMT (allows chroot into ARM64 rootfs)
# =============================================================================
RUN update-binfmts --enable qemu-aarch64 2>/dev/null || true

# =============================================================================
# SET UP BUILD DIRECTORY STRUCTURE
# =============================================================================
RUN mkdir -p \
    /opt/ghost-build \
    /opt/ghost-build/rootfs \
    /opt/ghost-build/kernel \
    /opt/ghost-build/uboot \
    /opt/ghost-build/output \
    /ghost

# =============================================================================
# COPY ghOSt BUILD SYSTEM
# =============================================================================
COPY . /ghost/

RUN chmod +x \
    /ghost/build.sh \
    /ghost/kernel/build-kernel.sh \
    /ghost/rootfs/build-rootfs.sh \
    /ghost/overlay/opt/ghost/scripts/configure.sh \
    /ghost/launcher/launcher.py \
    /ghost/stealthd/stealthd.py \
    /ghost/hey/hey.py \
    /ghost/firstboot/firstboot.sh \
    /ghost/firstboot/firstboot-interactive.sh \
    2>/dev/null || true

# =============================================================================
# OVERRIDE BUILD DIR IN CONFIG TO USE CONTAINER PATHS
# =============================================================================
RUN sed -i \
    's|BUILD_DIR=.*|BUILD_DIR="/opt/ghost-build"|g' \
    /ghost/config.sh

WORKDIR /ghost

# =============================================================================
# VOLUME: output directory mounted from host
# The finished .img.gz will appear here
# =============================================================================
VOLUME ["/opt/ghost-build/output"]

# =============================================================================
# ENTRYPOINT
# =============================================================================
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["build"]
