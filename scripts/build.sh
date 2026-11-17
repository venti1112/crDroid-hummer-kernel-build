#!/usr/bin/env bash

set -Eeuo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${RUNNER_TEMP:-/tmp}/hummer-build"
CLANG_DIR="${RUNNER_TEMP:-/tmp}/clang-r596125"
KERNEL_SUFFIX="${KERNEL_SUFFIX:-}"

echo "下载并配置 Clang"
mkdir -p "$CLANG_DIR"
curl -fL --retry 5 "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/29182889399818f97baa65ea238c80e8117981eb/clang-r596125.tar.gz" | tar -xz -C "$CLANG_DIR"
export PATH="$CLANG_DIR/bin:$PATH"

echo "克隆内核源码"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
git clone --depth=1 -b 17.0 https://github.com/crdroidandroid/android_kernel_oneplus_sm8750 "$WORKDIR/sm8750"
git clone --depth=1 -b 17.0 https://github.com/crdroidandroid/android_kernel_oneplus_sm8750-modules "$WORKDIR/sm8750-modules"
cd "$WORKDIR/sm8750"

echo "集成 SukiSU"
curl -fsSL "https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh" | bash -s builtin-new

echo "集成 SUSFS"
SUSFS_SHA="$(curl -fsSL 'https://gitlab.com/api/v4/projects/simonpunk/susfs4ksu/repository/branches/gki-android15-6.6' | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["id"])')"
curl -fsSL "https://gitlab.com/simonpunk/susfs4ksu/-/raw/$SUSFS_SHA/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch" -o "$WORKDIR/susfs.patch"
git apply "$WORKDIR/susfs.patch"
curl -fsSL "https://gitlab.com/simonpunk/susfs4ksu/-/raw/$SUSFS_SHA/kernel_patches/fs/susfs.c" -o fs/susfs.c
curl -fsSL "https://gitlab.com/simonpunk/susfs4ksu/-/raw/$SUSFS_SHA/kernel_patches/include/linux/susfs.h" -o include/linux/susfs.h
curl -fsSL "https://gitlab.com/simonpunk/susfs4ksu/-/raw/$SUSFS_SHA/kernel_patches/include/linux/susfs_def.h" -o include/linux/susfs_def.h

echo "Droidspaces 补丁"
curl -fsSL "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch" -o "$WORKDIR/droidspaces.patch"
patch -p1 < "$WORKDIR/droidspaces.patch"

echo "配置内核选项"
cat >"$WORKDIR/ci.config" <<'EOF'
CONFIG_KSU=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_INLINE_HOOK=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_USER_NS=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_MACVLAN=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP6_NF_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_TMPFS_XATTR=y
EOF

echo "合并内核选项"
make O=out ARCH=arm64 LLVM=1 gki_defconfig
scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/vendor/sun_perf.config
make O=out ARCH=arm64 LLVM=1 olddefconfig
scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/vendor/oplus/sun_perf.config
make O=out ARCH=arm64 LLVM=1 olddefconfig
scripts/kconfig/merge_config.sh -m -O out out/.config "$WORKDIR/ci.config"
make O=out ARCH=arm64 LLVM=1 olddefconfig

echo "拼 KERNELRELEASE"
KERNEL_VERSION="$(make -s kernelversion 2>/dev/null)"
KERNEL_ANDROID="$(sed -nE 's/^BRANCH=([^-]+)-.*/\1/p' build.config.common)"
KMI_GENERATION="$(sed -nE 's/^KMI_GENERATION=//p' build.config.common)"
KERNEL_SHA="$(git rev-parse --short=12 HEAD)"
KERNEL_LOCALVERSION="$(sed -nE 's/^CONFIG_LOCALVERSION="(.*)"$/\1/p' out/.config)"
KERNEL_RELEASE="${KERNEL_VERSION}-${KERNEL_ANDROID}-${KMI_GENERATION}-g${KERNEL_SHA}${KERNEL_LOCALVERSION}"
if [ -n "$KERNEL_SUFFIX" ]; then
    KERNEL_RELEASE="${KERNEL_RELEASE}-${KERNEL_SUFFIX}"
fi
OS_PATCH_LEVEL="$(date -u -d "@$(git log -1 --format=%ct)" +%Y-%m)"
echo "  KERNELRELEASE  = $KERNEL_RELEASE"
echo "  OS_PATCH_LEVEL = $OS_PATCH_LEVEL"

echo "编译"
rm -f out/include/config/kernel.release
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 KERNELRELEASE="$KERNEL_RELEASE" -j"$(nproc)" Image

echo "打包"
: >"$WORKDIR/ramdisk"
python3 "$CI_ROOT/tools/mkbootimg.py" \
    --kernel out/arch/arm64/boot/Image --ramdisk "$WORKDIR/ramdisk" \
    --header_version 4 --pagesize 4096 \
    --os_version 17.0.0 --os_patch_level "$OS_PATCH_LEVEL" --cmdline '' \
    -o "$CI_ROOT/boot.img"
truncate -s 96M "$CI_ROOT/boot.img"

printf 'kernel_release=%s\nos_patch_level=%s\n' "$KERNEL_RELEASE" "$OS_PATCH_LEVEL" >>"${GITHUB_OUTPUT:-/dev/null}"
