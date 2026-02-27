#!/bin/bash
set -euo pipefail

# build-image.sh - 构建用于 PVE 模板的自定义 qcow2 镜像
#
# 用法:
#   ./build-image.sh <os> [arch] [output_dir]
#   ./build-image.sh debian13
#   ./build-image.sh debian13 amd64
#   ./build-image.sh ubuntu2404 amd64 ./output
#
# 说明:
#   - 不在镜像内写死账号/密码/SSH key
#   - 账号、密钥、网络在 PVE 克隆实例后通过 cloud-init 注入

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
IMAGE_NAME="${1:-}"
ARCH="${2:-amd64}"
OUTPUT_DIR="${3:-${PROJECT_DIR}/output}"
CONFIG_PATH="${PROJECT_DIR}/images/${IMAGE_NAME}/config.yaml"
CACHE_DIR="${PROJECT_DIR}/.cache"

# CI 默认使用 software emulation，避免依赖宿主机 KVM。
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export LIBGUESTFS_BACKEND_SETTINGS="${LIBGUESTFS_BACKEND_SETTINGS:-force_tcg}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_args() {
    if [ -z "$IMAGE_NAME" ]; then
        log_error "请指定镜像，例如: debian13"
        echo "可用镜像:"
        find "${PROJECT_DIR}/images" -name config.yaml -exec dirname {} \; | xargs -I {} basename {} | sort -u | sed 's/^/  - /'
        exit 1
    fi

    if [ ! -f "$CONFIG_PATH" ]; then
        log_error "配置文件不存在: $CONFIG_PATH"
        exit 1
    fi

    if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
        log_error "不支持的架构: $ARCH (支持: amd64, arm64)"
        exit 1
    fi
}

check_tools() {
    local missing=()
    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v virt-customize >/dev/null 2>&1 || missing+=("virt-customize")
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v yq >/dev/null 2>&1 || missing+=("yq")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少工具: ${missing[*]}"
        echo "安装示例:"
        echo "  sudo apt-get update && sudo apt-get install -y qemu-utils libguestfs-tools wget"
        exit 1
    fi
}

read_config() {
    NAME=$(yq '.name' "$CONFIG_PATH")
    VERSION=$(yq '.version' "$CONFIG_PATH")
    SOURCE_URL=$(yq ".source.${ARCH}" "$CONFIG_PATH")
    DISK_SIZE=$(yq '.disk.size // "10G"' "$CONFIG_PATH")
    TIMEZONE=$(yq '.settings.timezone // "Etc/UTC"' "$CONFIG_PATH")
    HOSTNAME=$(yq '.settings.hostname // "cloud-template"' "$CONFIG_PATH")
    LOCALE=$(yq '.settings.locale // "en_US.UTF-8"' "$CONFIG_PATH")
    APT_MIRROR=$(yq '.apt.mirror // ""' "$CONFIG_PATH")
    DNF_MIRROR=$(yq '.dnf.mirror // ""' "$CONFIG_PATH")

    if [ "$SOURCE_URL" = "null" ] || [ -z "$SOURCE_URL" ]; then
        log_error "配置文件中未找到 ${ARCH} 的源镜像 URL"
        exit 1
    fi

    if [[ "$SOURCE_URL" == *"rocky"* ]] || [[ "$SOURCE_URL" == *"centos"* ]] || [[ "$SOURCE_URL" == *"rhel"* ]]; then
        OS_FAMILY="rhel"
    else
        OS_FAMILY="debian"
    fi
}

download_source() {
    local source_file="${CACHE_DIR}/$(basename "$SOURCE_URL")"

    mkdir -p "$CACHE_DIR"

    if [ -f "$source_file" ]; then
        log_info "复用缓存镜像: $source_file"
        SOURCE_FILE="$source_file"
        return
    fi

    log_info "下载源镜像: $SOURCE_URL"
    wget -q --show-progress "$SOURCE_URL" -O "${source_file}.tmp"
    mv "${source_file}.tmp" "$source_file"
    SOURCE_FILE="$source_file"
}

build_image() {
    local output_file="$1"

    mkdir -p "$OUTPUT_DIR"
    cp "$SOURCE_FILE" "$output_file"
    qemu-img resize "$output_file" "$DISK_SIZE"

    local customize_args=("-a" "$output_file")

    # 基础系统设置
    customize_args+=("--hostname" "$HOSTNAME")
    customize_args+=("--timezone" "$TIMEZONE")

    if [ "$OS_FAMILY" = "debian" ]; then
        customize_args+=("--run-command" "echo 'LANG=${LOCALE}' > /etc/default/locale || true")
        if [ -n "$APT_MIRROR" ] && [ "$APT_MIRROR" != "null" ]; then
            local codename
            codename=$(echo "$SOURCE_URL" | sed -n 's#.*/images/cloud/\([^/]*\)/.*#\1#p')
            codename="${codename:-bookworm}"
            customize_args+=(
                "--run-command" "rm -f /etc/apt/sources.list.d/*.sources 2>/dev/null || true"
                "--run-command" "echo 'deb ${APT_MIRROR} ${codename} main contrib non-free non-free-firmware' > /etc/apt/sources.list"
                "--run-command" "echo 'deb ${APT_MIRROR} ${codename}-updates main contrib non-free non-free-firmware' >> /etc/apt/sources.list"
                "--run-command" "echo 'deb ${APT_MIRROR}-security ${codename}-security main contrib non-free non-free-firmware' >> /etc/apt/sources.list"
                "--run-command" "apt-get update || true"
            )
        fi
    else
        if [ -n "$DNF_MIRROR" ] && [ "$DNF_MIRROR" != "null" ]; then
            customize_args+=("--run-command" "sed -i 's|https://dl.rockylinux.org|${DNF_MIRROR}|g' /etc/yum.repos.d/*.repo 2>/dev/null || true")
        fi
        customize_args+=("--run-command" "dnf clean all || true")
    fi

    # 安装软件包
    local packages
    packages=$(yq '.packages[]' "$CONFIG_PATH" 2>/dev/null | paste -sd, - || true)
    if [ -n "$packages" ]; then
        customize_args+=("--install" "$packages")
    fi

    # 写入文件
    local file_count
    file_count=$(yq '.files | length' "$CONFIG_PATH")
    if [[ "$file_count" =~ ^[0-9]+$ ]] && [ "$file_count" -gt 0 ]; then
        for ((i=0; i<file_count; i++)); do
            local file_path file_content file_perm
            file_path=$(yq ".files[$i].path" "$CONFIG_PATH")
            file_content=$(yq ".files[$i].content" "$CONFIG_PATH")
            file_perm=$(yq ".files[$i].permissions // \"0644\"" "$CONFIG_PATH")
            customize_args+=("--write" "${file_path}:${file_content}")
            customize_args+=("--run-command" "chmod ${file_perm} ${file_path}")
        done
    fi

    # 运行自定义命令
    local cmd_count
    cmd_count=$(yq '.commands | length' "$CONFIG_PATH")
    if [[ "$cmd_count" =~ ^[0-9]+$ ]] && [ "$cmd_count" -gt 0 ]; then
        for ((i=0; i<cmd_count; i++)); do
            local cmd
            cmd=$(yq ".commands[$i]" "$CONFIG_PATH")
            customize_args+=("--run-command" "$cmd")
        done
    fi

    # 保持 cloud-init 可在实例首次启动时重新执行
    customize_args+=("--run-command" "cloud-init clean --logs || true")

    log_info "开始定制镜像..."
    sudo virt-customize "${customize_args[@]}"

    # 压缩并生成校验和
    local compressed_file="${output_file%.qcow2}-compressed.qcow2"
    qemu-img convert -O qcow2 -c "$output_file" "$compressed_file"
    mv "$compressed_file" "$output_file"

    sha256sum "$output_file" > "${output_file}.sha256"

    log_info "构建完成: $output_file"
    qemu-img info "$output_file"
}

main() {
    check_args
    check_tools
    read_config
    download_source

    local output_file="${OUTPUT_DIR}/${NAME}-${ARCH}.qcow2"

    log_info "========================================"
    log_info "开始构建镜像: ${IMAGE_NAME} (${ARCH})"
    log_info "版本: ${VERSION}"
    log_info "输出: ${output_file}"
    log_info "libguestfs backend: ${LIBGUESTFS_BACKEND}"
    log_info "backend settings: ${LIBGUESTFS_BACKEND_SETTINGS}"
    log_info "========================================"

    build_image "$output_file"

    log_info "========================================"
    log_info "构建成功"
    log_info "文件: ${output_file}"
    log_info "校验: ${output_file}.sha256"
    log_info "========================================"
}

main
