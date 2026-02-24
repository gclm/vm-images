#!/bin/bash
set -e

# build-image.sh - 构建自定义镜像
#
# 用法:
#   ./build-image.sh <os> [arch]
#   ./build-image.sh debian12          # 默认 amd64
#   ./build-image.sh debian12 amd64
#   ./build-image.sh debian12 arm64
#
# 环境变量:
#   SSH_PUBLIC_KEY - SSH 公钥 (必填)
#   ROOT_PASSWORD  - root 密码 (必填)
#   OUTPUT_DIR     - 输出目录 (默认: ./output)
#   LIBGUESTFS_BACKEND - libguestfs 后端 (默认: direct)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"

# 临时文件数组
declare -a tmp_files=()

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 清理函数
cleanup() {
    for tmp in "${tmp_files[@]}"; do
        rm -f "$tmp" 2>/dev/null || true
    done
}
trap cleanup EXIT

# 检查参数
if [ -z "$1" ]; then
    log_error "请指定镜像配置，例如: debian12"
    echo "可用配置:"
    find "${PROJECT_DIR}/images" -name "config.yaml" -exec dirname {} \; | xargs -I {} basename {} | sort -u | sed 's/^/  - /'
    exit 1
fi

IMAGE_NAME="$1"
ARCH="${2:-amd64}"
CONFIG_PATH="${PROJECT_DIR}/images/${IMAGE_NAME}/config.yaml"

if [ ! -f "$CONFIG_PATH" ]; then
    log_error "配置文件不存在: $CONFIG_PATH"
    exit 1
fi

# 加载 .env 文件
if [ -f "${PROJECT_DIR}/.env" ]; then
    log_info "加载 .env 文件..."
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
fi

# 设置 libguestfs 后端 (GitHub Actions 不支持 KVM)
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_BACKEND_SETTINGS="${LIBGUESTFS_BACKEND_SETTINGS:-force_tcg}"
log_info "使用 libguestfs backend: ${LIBGUESTFS_BACKEND}"
log_info "使用 backend settings: ${LIBGUESTFS_BACKEND_SETTINGS}"

# 检查环境变量
if [ -z "$SSH_PUBLIC_KEY" ]; then
    log_error "SSH_PUBLIC_KEY 环境变量未设置"
    exit 1
fi

if [ -z "$ROOT_PASSWORD" ]; then
    log_error "ROOT_PASSWORD 环境变量未设置"
    exit 1
fi

# 检查工具
check_tools() {
    local missing=()
    command -v qemu-img &> /dev/null || missing+=("qemu-img")
    command -v virt-customize &> /dev/null || missing+=("virt-customize")
    command -v wget &> /dev/null || missing+=("wget")
    command -v yq &> /dev/null || missing+=("yq")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少工具: ${missing[*]}"
        echo "安装命令:"
        echo "  sudo apt install qemu-utils libguestfs-tools wget"
        echo "  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
        exit 1
    fi
}

# 读取配置
read_config() {
    local config_file="$1"
    local arch="$2"
    NAME=$(yq '.name' "$config_file")
    VERSION=$(yq '.version' "$config_file")
    SOURCE_URL=$(yq ".source.${arch}" "$config_file")
    DISK_SIZE=$(yq '.disk.size' "$config_file")
    TIMEZONE=$(yq '.settings.timezone' "$config_file")
    HOSTNAME=$(yq '.settings.hostname' "$config_file")
    APT_MIRROR=$(yq '.apt.mirror' "$config_file")
    DNF_MIRROR=$(yq '.dnf.mirror' "$config_file")

    if [ "$SOURCE_URL" = "null" ] || [ -z "$SOURCE_URL" ]; then
        log_error "配置文件中未找到架构 ${arch} 的镜像 URL"
        exit 1
    fi

    # 检测操作系统类型
    if [[ "$SOURCE_URL" == *"rocky"* ]] || [[ "$SOURCE_URL" == *"centos"* ]] || [[ "$SOURCE_URL" == *"rhel"* ]]; then
        OS_FAMILY="rhel"
    else
        OS_FAMILY="debian"
    fi
}

# 下载源镜像
download_source() {
    local source_url="$1"
    local source_file="$2"

    if [ -f "$source_file" ]; then
        log_info "源镜像已存在: $source_file"
        return
    fi

    log_info "下载源镜像: $source_url"
    wget -q --show-progress "$source_url" -O "$source_file.tmp"
    mv "$source_file.tmp" "$source_file"
}

# 构建镜像
build_image() {
    local config_path="$1"
    local output_file="$2"
    local arch="$3"

    log_info "读取配置: $config_path"
    read_config "$config_path" "$arch"

    log_info "镜像名称: $NAME"
    log_info "版本: $VERSION"
    log_info "架构: $arch"
    log_info "系统类型: $OS_FAMILY"

    # 创建输出目录
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${PROJECT_DIR}/.cache"

    # 下载源镜像
    local source_file="${PROJECT_DIR}/.cache/$(basename "$SOURCE_URL")"
    download_source "$SOURCE_URL" "$source_file"

    # 复制并扩展镜像
    log_info "准备镜像..."
    cp "$source_file" "$output_file"
    qemu-img resize "$output_file" "$DISK_SIZE"

    # 读取软件包列表
    local packages=$(yq '.packages[]' "$config_path" | tr '\n' ',' | sed 's/,$//')

    # 构建 virt-customize 命令
    local customize_args=("-a" "$output_file")

    # 根据系统类型设置初始化命令
    if [ "$OS_FAMILY" = "debian" ]; then
        customize_args+=("--run-command" "dpkg --configure -a || true")

        # APT 镜像源 - Debian 12 cloud 镜像使用 /etc/apt/mirrors/ 格式
        if [ -n "$APT_MIRROR" ] && [ "$APT_MIRROR" != "null" ]; then
            customize_args+=(
                # 配置 DNS 以确保可以解析域名
                "--run-command" "echo 'nameserver 8.8.8.8' > /etc/resolv.conf 2>/dev/null || true"
                "--run-command" "echo 'nameserver 8.8.4.4' >> /etc/resolv.conf 2>/dev/null || true"
                # 直接写入新的 mirror list (Debian 12 cloud 格式)
                "--run-command" "echo 'deb ${APT_MIRROR} bookworm main contrib non-free non-free-firmware' > /etc/apt/sources.list 2>/dev/null || true"
                "--run-command" "echo 'deb ${APT_MIRROR} bookworm-updates main contrib non-free non-free-firmware' >> /etc/apt/sources.list 2>/dev/null || true"
                "--run-command" "echo 'deb ${APT_MIRROR} bookworm-backports main contrib non-free non-free-firmware' >> /etc/apt/sources.list 2>/dev/null || true"
                "--run-command" "echo 'deb ${APT_MIRROR}-security bookworm-security main contrib non-free non-free-firmware' >> /etc/apt/sources.list 2>/dev/null || true"
                # 备份旧的 mirror list 文件
                "--run-command" "mv /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.bak 2>/dev/null || true"
                "--run-command" "apt-get update || true"  # 更新包列表
            )
        else
            # 没有 mirror 配置时，配置 DNS 并更新
            customize_args+=(
                "--run-command" "echo 'nameserver 8.8.8.8' > /etc/resolv.conf 2>/dev/null || true"
                "--run-command" "apt-get update || true"
            )
        fi
    else
        # RHEL 系列
        customize_args+=("--run-command" "dnf clean all || true")

        # DNF 镜像源 (Rocky Linux)
        if [ -n "$DNF_MIRROR" ] && [ "$DNF_MIRROR" != "null" ]; then
            customize_args+=(
                "--run-command" "sed -i 's|https://dl.rockylinux.org|${DNF_MIRROR}|g' /etc/yum.repos.d/*.repo 2>/dev/null || true"
            )
        fi
    fi

    # 安装软件包
    if [ -n "$packages" ]; then
        customize_args+=("--install" "$packages")
    fi

    # 设置时区
    if [ -n "$TIMEZONE" ] && [ "$TIMEZONE" != "null" ]; then
        customize_args+=("--timezone" "$TIMEZONE")
    fi

    # 设置主机名
    if [ -n "$HOSTNAME" ] && [ "$HOSTNAME" != "null" ]; then
        customize_args+=("--hostname" "$HOSTNAME")
    fi

    # 设置 root 密码 (使用文件避免特殊字符问题)
    local root_password_file=$(mktemp)
    echo -n "$ROOT_PASSWORD" > "$root_password_file"
    customize_args+=("--root-password" "file:${root_password_file}")
    tmp_files+=("$root_password_file")

    # 创建用户并设置密码和 SSH 密钥
    local first_user=$(yq '.users[] | select(.name != "root") | .name' "$config_path" | head -1)
    if [ -n "$first_user" ]; then
        if [ "$OS_FAMILY" = "debian" ]; then
            customize_args+=("--run-command" "useradd -m -s /bin/bash -G sudo ${first_user} 2>/dev/null || true")
        else
            # RHEL 使用 wheel 组
            customize_args+=("--run-command" "useradd -m -s /bin/bash -G wheel ${first_user} 2>/dev/null || true")
        fi
        # 使用密码文件避免特殊字符问题
        local user_password_file=$(mktemp)
        echo -n "$ROOT_PASSWORD" > "$user_password_file"
        customize_args+=("--password" "${first_user}:file:${user_password_file}")
        tmp_files+=("$user_password_file")
        customize_args+=("--ssh-inject" "${first_user}:string:${SSH_PUBLIC_KEY}")
    fi

    # 写入文件
    local file_count=$(yq '.files | length' "$config_path")
    for ((i=0; i<file_count; i++)); do
        local file_path=$(yq ".files[$i].path" "$config_path")
        local file_content=$(yq ".files[$i].content" "$config_path")
        local file_perm=$(yq ".files[$i].permissions" "$config_path")

        # 创建临时文件
        local tmp_file=$(mktemp)
        echo "$file_content" > "$tmp_file"

        customize_args+=("--copy-in" "${tmp_file}:${file_path}")
        customize_args+=("--run-command" "chmod ${file_perm} ${file_path}")

        tmp_files+=("$tmp_file")
    done

    # 运行命令
    local cmd_count=$(yq '.commands | length' "$config_path")
    for ((i=0; i<cmd_count; i++)); do
        local cmd=$(yq ".commands[$i]" "$config_path")
        customize_args+=("--run-command" "$cmd")
    done

    # 执行 virt-customize
    # 临时禁用 passt（GitHub Actions 环境中 passt 有权限问题）
    log_info "定制镜像中..."
    if command -v passt &> /dev/null; then
        log_warn "暂时禁用 passt，使用 slirp 网络..."
        sudo mv /usr/bin/passt /usr/bin/passt.disabled 2>/dev/null || true
    fi
    sudo virt-customize "${customize_args[@]}"
    # 恢复 passt
    sudo mv /usr/bin/passt.disabled /usr/bin/passt 2>/dev/null || true

    # 压缩镜像
    log_info "压缩镜像..."
    local compressed_file="${output_file%.qcow2}-compressed.qcow2"
    qemu-img convert -O qcow2 -c "$output_file" "$compressed_file"
    mv "$compressed_file" "$output_file"

    # 生成校验和
    log_info "生成校验和..."
    sha256sum "$output_file" > "${output_file}.sha256"

    log_info "构建完成: $output_file"
    qemu-img info "$output_file"
}

# 主流程
main() {
    check_tools

    local output_name
    output_name=$(yq '.name' "$CONFIG_PATH")

    local output_file="${OUTPUT_DIR}/${output_name}-${ARCH}.qcow2"

    log_info "========================================"
    log_info "开始构建镜像: ${IMAGE_NAME} (${ARCH})"
    log_info "========================================"

    build_image "$CONFIG_PATH" "$output_file" "$ARCH"

    log_info "========================================"
    log_info "构建成功!"
    log_info "输出文件: $output_file"
    log_info "校验文件: ${output_file}.sha256"
    log_info "========================================"
}

main
