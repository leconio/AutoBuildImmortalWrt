#!/usr/bin/env bash
# shellcheck disable=SC2016

# ========== turboacc 部分开始 ==========
trap 'rm -rf "$TMPDIR"' EXIT
TMPDIR=$(mktemp -d) || exit 1

NO_SFE=false
LOCAL_PACKAGE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-sfe)
            NO_SFE=true
            shift
            ;;
        --local-pkg)
            LOCAL_PACKAGE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if ! [ -d "./package" ]; then
    echo "./package not found"
    exit 1
fi

VERSION_NUMBER=$(sed -n '/VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),.*)/p' include/version.mk | sed -e 's/.*$(VERSION_NUMBER),//' -e 's/)//')
kernel_versions="$(find "./include" | sed -n '/kernel-[0-9]/p' | sed -e "s@./include/kernel-@@" | sed ':a;N;$!ba;s/\n/ /g')"
if [ -z "$kernel_versions" ]; then
    kernel_versions="$(find "./target/linux/generic" | sed -n '/kernel-[0-9]/p' | sed -e "s@./target/linux/generic/kernel-@@" | sed ':a;N;$!ba;s/\n/ /g')"
fi
if [ -z "$kernel_versions" ]; then
    echo "Error: Unable to get kernel version, script exited"
    exit 1
fi
echo "kernel version: $kernel_versions, No SFE: $NO_SFE"

if [ -d "./package/turboacc" ]; then
    echo "./package/turboacc already exists, delete it? [Y/N]"
    read -r answer
    if [[ $answer =~ ^[Yy]$ ]]; then
        rm -rf "./package/turboacc"
    else
        echo "You selected 'No', script exited"
        exit 0
    fi
fi

git clone --depth=1 --single-branch https://github.com/chenmozhijin/turboacc "$TMPDIR/turboacc/turboacc" || exit 1
if [ -n "$LOCAL_PACKAGE" ]; then
    echo "Using local package: $LOCAL_PACKAGE"
    cp -RT "$LOCAL_PACKAGE" "$TMPDIR/package" || exit 1
else
    git clone --depth=1 --single-branch --branch "package" https://github.com/chenmozhijin/turboacc "$TMPDIR/package" || exit 1
fi

cp -r "$TMPDIR/turboacc/turboacc/luci-app-turboacc" "$TMPDIR/turboacc/luci-app-turboacc"
rm -rf "$TMPDIR/turboacc/turboacc"
cp -r "$TMPDIR/package/nft-fullcone" "$TMPDIR/turboacc/nft-fullcone" || exit 1
if [ "$NO_SFE" = false ]; then
    cp -r "$TMPDIR/package/shortcut-fe" "$TMPDIR/turboacc/shortcut-fe"
fi

for kernel_version in $kernel_versions; do
    patch_953_path="./target/linux/generic/hack-$kernel_version/953-net-patch-linux-kernel-to-support-shortcut-fe.patch"
    patch_613_path="./target/linux/generic/pending-$kernel_version/613-netfilter_optional_tcp_window_check.patch"
    if [ "$kernel_version" = "6.12" ] || [ "$kernel_version" = "6.6" ] || [ "$kernel_version" = "6.1" ] || [ "$kernel_version" = "5.15" ]; then
        patch_952_path="./target/linux/generic/hack-$kernel_version/952-add-net-conntrack-events-support-multiple-registrant.patch"
        patch_952="952-add-net-conntrack-events-support-multiple-registrant.patch"
    elif [ "$kernel_version" = "5.10" ]; then
        patch_952_path="./target/linux/generic/hack-$kernel_version/952-net-conntrack-events-support-multiple-registrant.patch"
        patch_952="952-net-conntrack-events-support-multiple-registrant.patch"
    else
        echo "Unsupported kernel version: $kernel_version"
        exit 1
    fi

    for file_path in "$patch_952_path" "$patch_953_path" "$patch_613_path"; do
        if [ -a "$file_path" ]; then
            echo "$file_path already exists, delete."
            rm -rf "$file_path"
        fi
    done

    cp -f "$TMPDIR/package/hack-$kernel_version/$patch_952" "$patch_952_path"
    if [ "$NO_SFE" = false ]; then
        cp -f "$TMPDIR/package/hack-$kernel_version/953-net-patch-linux-kernel-to-support-shortcut-fe.patch" "$patch_953_path"
        cp -f "$TMPDIR/package/pending-$kernel_version/613-netfilter_optional_tcp_window_check.patch" "$patch_613_path"
    fi

    if ! grep -q "CONFIG_NF_CONNTRACK_CHAIN_EVENTS" "./target/linux/generic/config-$kernel_version"; then
        echo "# CONFIG_NF_CONNTRACK_CHAIN_EVENTS is not set" >> "./target/linux/generic/config-$kernel_version"
    fi
    if [ "$NO_SFE" = false ] && ! grep -q "CONFIG_SHORTCUT_FE" "./target/linux/generic/config-$kernel_version"; then
        echo "# CONFIG_SHORTCUT_FE is not set" >> "./target/linux/generic/config-$kernel_version"
    fi
done

cp -r "$TMPDIR/turboacc" "./package/turboacc"

FIREWALL4_VERSION=$(grep -o 'PKG_SOURCE_VERSION:=.*' ./package/network/config/firewall4/Makefile | cut -d '=' -f 2)
NFTABLES_VERSION=$(grep -o 'PKG_VERSION:=.*' ./package/network/utils/nftables/Makefile | cut -d '=' -f 2)
LIBNFTNL_VERSION=$(grep -o 'PKG_VERSION:=.*' ./package/libs/libnftnl/Makefile | cut -d '=' -f 2)

rm -rf ./package/libs/libnftnl ./package/network/config/firewall4 ./package/network/utils/nftables

if ! [ -d "$TMPDIR/package/firewall4-$FIREWALL4_VERSION" ]; then
    echo "firewall4 version $FIREWALL4_VERSION not found, using latest version"
    FIREWALL4_VERSION=$(grep -o 'FIREWALL4_VERSION=.*' "$TMPDIR/package/version" | cut -d '=' -f 2)
fi
if ! [ -d "$TMPDIR/package/nftables-$NFTABLES_VERSION" ]; then
    echo "nftables version $NFTABLES_VERSION not found, using latest version"
    NFTABLES_VERSION=$(grep -o 'NFTABLES_VERSION=.*' "$TMPDIR/package/version" | cut -d '=' -f 2)
fi
if ! [ -d "$TMPDIR/package/libnftnl-$LIBNFTNL_VERSION" ]; then
    echo "libnftnl version $LIBNFTNL_VERSION not found, using latest version"
    LIBNFTNL_VERSION=$(grep -o 'LIBNFTNL_VERSION=.*' "$TMPDIR/package/version" | cut -d '=' -f 2)
fi
cp -RT "$TMPDIR/package/firewall4-$FIREWALL4_VERSION/firewall4" ./package/network/config/firewall4
cp -RT "$TMPDIR/package/libnftnl-$LIBNFTNL_VERSION/libnftnl" ./package/libs/libnftnl
cp -RT "$TMPDIR/package/nftables-$NFTABLES_VERSION/nftables" ./package/network/utils/nftables

echo "TurboACC & firewall4/nftables/libnftnl patching Finished"

# ========== turboacc 部分结束 ==========
# ========== imagebuilder / 自定义构建部分开始 ==========

# 注意：这里假定当前目录是 imagebuilder 的 /home/build/immortalwrt 之类环境。
# 如果你实际路径不同，把下面的路径改掉。

# 加载自定义第三方软件包变量
if [ -f shell/custom-packages.sh ]; then
    # shell/custom-packages.sh 里应该定义 CUSTOM_PACKAGES、PROFILE、ENABLE_PPPOE 等
    # 比如：CUSTOM_PACKAGES="luci-app-passwall ..." 之类
    # PROFILE / INCLUDE_DOCKER / ENABLE_PPPOE 从外部环境传进来
    source shell/custom-packages.sh
fi

# 下载第三方 run 仓库
echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

# 拷贝 run/arm64 下所有 run 文件和 ipk 文件到 extra-packages 目录
mkdir -p /home/build/immortalwrt/extra-packages
cp -r /tmp/store-run-repo/run/arm64/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true

echo "✅ Run files copied to extra-packages:"
ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null || echo "No .run files"

# 解压并拷贝 ipk 到 packages 目录
sh shell/prepare-packages.sh
ls -lah /home/build/immortalwrt/packages/

# 添加架构优先级信息
sed -i '1i\
arch aarch64_generic 10\n\
arch aarch64_cortex-a53 15' repositories.conf

# 输出 profile 等信息
echo "Building for profile: $PROFILE"
echo "Include Docker: $INCLUDE_DOCKER"

# 创建 pppoe-settings
echo "Create pppoe-settings"
mkdir -p /home/build/immortalwrt/files/etc/config

cat << EOF_PPPOE > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF_PPPOE

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."

# 定义所需安装的包列表
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
# 24.10.0
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# 静态文件服务器 dufs
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"

# 第三方软件包（custom-packages.sh 里定义的 CUSTOM_PACKAGES）
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    echo "Model: $PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn luci-i18n-homeproxy-zh-cn"
else
    echo "Other Model: $PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 如果包含 openclash，则拉 core + geo 数据
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- "$META_URL" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# 执行 imagebuilder 构建
make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
exit 0
