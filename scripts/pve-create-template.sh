#!/bin/bash
set -euo pipefail

# pve-create-template.sh - 在 PVE 上下载 qcow2 并创建模板
#
# 用法:
#   ./pve-create-template.sh <os> <arch> <vmid> [options]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 默认参数
STORAGE=""
BRIDGE="vmbr0"
MEMORY=2048
CORES=2
DISK_SIZE="10G"

RELEASE="latest"
GH_REPO="${GH_REPO:-gclm/vm-images}"
IMAGE_URL=""
SHA256=""
SHA256_URL=""

USE_PROXY=false
PROXY_URL="${PROXY_URL:-https://proxy.991201.xyz/}"

RELEASE_TAG=""
RESOLVED_IMAGE_URL=""
REMOTE_SHA256=""
IMAGE_FILE=""

declare -A IMAGE_NAMES=(
    ["debian12"]="debian12"
    ["debian13"]="debian13"
    ["ubuntu2204"]="ubuntu2204"
    ["ubuntu2404"]="ubuntu2404"
    ["rocky10"]="rocky10"
)

show_help() {
    cat << EOF
用法: $0 <os> <arch> <vmid> [options]

参数:
  os                 操作系统 (debian12, debian13, ubuntu2204, ubuntu2404, rocky10)
  arch               架构 (amd64, arm64)
  vmid               VM ID (数字)

选项:
  --storage NAME     存储名称 (默认: 自动检测)
  --bridge NAME      网桥名称 (默认: vmbr0)
  --memory MB        内存大小 (默认: 2048)
  --cores N          CPU 核心数 (默认: 2)
  --disk-size SIZE   磁盘大小 (默认: 10G)
  --release TAG      GitHub Release 标签 (默认: latest)
  --repo OWNER/REPO  GitHub 仓库 (默认: gclm/vm-images)
  --image-url URL    直接指定 qcow2 下载地址（优先级最高）
  --sha256 HASH      显式指定镜像 SHA256（64位十六进制）
  --sha256-url URL   指定 SHA256 文件下载地址
  --proxy            启用代理下载
  --proxy-url URL    自定义代理地址

说明:
  - 脚本会在 /tmp 检查同名镜像，若 SHA256 一致则复用，不一致则覆盖下载。
  - GitHub release 默认使用 <image>.qcow2.sha256 作为校验文件。
  - 使用 --image-url 时，若未指定 --sha256/--sha256-url，会尝试 <image-url>.sha256。
EOF
    exit 0
}

parse_args() {
    if [ $# -lt 3 ]; then
        show_help
    fi

    OS="$1"
    ARCH="$2"
    VMID="$3"
    shift 3

    if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
        log_error "VMID 必须是数字: $VMID"
        exit 1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --storage) STORAGE="$2"; shift 2 ;;
            --bridge) BRIDGE="$2"; shift 2 ;;
            --memory) MEMORY="$2"; shift 2 ;;
            --cores) CORES="$2"; shift 2 ;;
            --disk-size) DISK_SIZE="$2"; shift 2 ;;
            --release) RELEASE="$2"; shift 2 ;;
            --repo) GH_REPO="$2"; shift 2 ;;
            --image-url) IMAGE_URL="$2"; shift 2 ;;
            --sha256) SHA256="$2"; shift 2 ;;
            --sha256-url) SHA256_URL="$2"; shift 2 ;;
            --proxy) USE_PROXY=true; shift ;;
            --proxy-url) PROXY_URL="$2"; USE_PROXY=true; shift 2 ;;
            -h|--help) show_help ;;
            *) log_error "未知选项: $1"; exit 1 ;;
        esac
    done

    if [ -z "${IMAGE_NAMES[$OS]:-}" ]; then
        log_error "不支持的操作系统: $OS"
        echo "支持: ${!IMAGE_NAMES[*]}"
        exit 1
    fi

    if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
        log_error "不支持的架构: $ARCH (支持: amd64, arm64)"
        exit 1
    fi

    if [ -n "$SHA256" ] && [ -n "$SHA256_URL" ]; then
        log_error "--sha256 和 --sha256-url 不能同时使用"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v qm >/dev/null 2>&1 || missing+=("qm")
    command -v pvesm >/dev/null 2>&1 || missing+=("pvesm")
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        exit 1
    fi

    if [ ! -f /etc/pve/.vmlist ]; then
        log_error "此脚本必须在 Proxmox VE 上运行"
        exit 1
    fi
}

detect_storage() {
    if [ -n "$STORAGE" ]; then
        if ! pvesm status | awk 'NR>1 {print $1}' | grep -qw "$STORAGE"; then
            log_error "存储不存在: $STORAGE"
            exit 1
        fi
        return
    fi

    local candidate
    candidate=$(pvesm status | awk 'NR>1 && $3=="active" {print $1; exit}')
    if [ -z "$candidate" ]; then
        log_error "未检测到可用存储"
        exit 1
    fi
    STORAGE="$candidate"
    log_info "自动选择存储: $STORAGE"
}

apply_proxy() {
    local url="$1"
    if [ "$USE_PROXY" = true ]; then
        local base="${PROXY_URL%/}/"
        echo "${base}${url}"
    else
        echo "$url"
    fi
}

resolve_release_tag() {
    if [ -n "$IMAGE_URL" ]; then
        return
    fi

    if [ "$RELEASE" != "latest" ]; then
        RELEASE_TAG="$RELEASE"
        return
    fi

    log_step "查询 ${GH_REPO} 最新 release"
    RELEASE_TAG=$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)

    if [ -z "$RELEASE_TAG" ]; then
        log_error "无法获取最新 release tag，请使用 --release 显式指定"
        exit 1
    fi

    log_info "最新 release: ${RELEASE_TAG}"
}

resolve_urls() {
    local image_name="${IMAGE_NAMES[$OS]}"

    if [ -n "$IMAGE_URL" ]; then
        RESOLVED_IMAGE_URL="$IMAGE_URL"
    else
        resolve_release_tag
        RESOLVED_IMAGE_URL="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${image_name}-${ARCH}.qcow2"
        if [ -z "$SHA256" ] && [ -z "$SHA256_URL" ]; then
            SHA256_URL="${RESOLVED_IMAGE_URL}.sha256"
        fi
    fi

    if [ -n "$IMAGE_URL" ] && [ -z "$SHA256" ] && [ -z "$SHA256_URL" ]; then
        SHA256_URL="${RESOLVED_IMAGE_URL}.sha256"
    fi
}

resolve_remote_sha256() {
    if [ -n "$SHA256" ]; then
        REMOTE_SHA256="$SHA256"
    else
        if [ -z "$SHA256_URL" ]; then
            log_error "无法获取 SHA256：请使用 --sha256 或 --sha256-url"
            exit 1
        fi

        log_step "下载 SHA256 校验文件"
        local checksum_content
        local effective_sha256_url
        effective_sha256_url="$(apply_proxy "$SHA256_URL")"
        log_info "SHA256 URL: $effective_sha256_url"
        checksum_content=$(curl -fsSL "$effective_sha256_url") || {
            log_error "下载 SHA256 文件失败: $SHA256_URL"
            exit 1
        }

        REMOTE_SHA256=$(printf '%s\n' "$checksum_content" | tr -d '\r' | awk 'NF>0 {print $1; exit}')
    fi

    REMOTE_SHA256=$(printf '%s' "$REMOTE_SHA256" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$REMOTE_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
        log_error "无效的 SHA256: $REMOTE_SHA256"
        exit 1
    fi

    log_info "远端 SHA256: $REMOTE_SHA256"
}

download_image() {
    local image_name="${IMAGE_NAMES[$OS]}"
    local image_file="/tmp/${image_name}-${ARCH}.qcow2"

    local effective_url
    effective_url=$(apply_proxy "$RESOLVED_IMAGE_URL")

    if [ -f "$image_file" ]; then
        local local_sha
        local_sha=$(sha256sum "$image_file" | awk '{print $1}')
        if [ "$local_sha" = "$REMOTE_SHA256" ]; then
            IMAGE_FILE="$image_file"
            log_info "本地镜像校验一致，复用: $IMAGE_FILE"
            return
        fi
        log_warn "本地镜像 SHA256 不一致，重新下载覆盖"
        rm -f "$image_file"
    fi

    log_step "下载 qcow2 镜像"
    log_info "URL: $effective_url"

    wget -q --show-progress "$effective_url" -O "${image_file}.tmp"
    local downloaded_sha
    downloaded_sha=$(sha256sum "${image_file}.tmp" | awk '{print $1}')

    if [ "$downloaded_sha" != "$REMOTE_SHA256" ]; then
        rm -f "${image_file}.tmp"
        log_error "下载后 SHA256 校验失败: $downloaded_sha != $REMOTE_SHA256"
        exit 1
    fi

    mv "${image_file}.tmp" "$image_file"
    IMAGE_FILE="$image_file"
    log_info "镜像下载并校验成功: $IMAGE_FILE"
}

create_vm_template() {
    local image_name="${IMAGE_NAMES[$OS]}"
    local net_queues="$CORES"

    if qm status "$VMID" >/dev/null 2>&1; then
        log_error "VMID 已存在: $VMID"
        exit 1
    fi

    # virtio-net 多队列最多 8，避免队列过多带来调度开销
    if [ "$net_queues" -gt 8 ]; then
        net_queues=8
    fi
    if [ "$net_queues" -lt 1 ]; then
        net_queues=1
    fi

    log_step "创建 VM: $VMID"
    log_info "性能优化: numa=1 balloon=0 net.queues=${net_queues} scsi(iothread,discard,ssd)"

    qm create "$VMID" \
        --name "${image_name}-${ARCH}" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --cpu host \
        --machine q35 \
        --numa 1 \
        --balloon 0 \
        --net0 "virtio,bridge=${BRIDGE},queues=${net_queues}" \
        --scsihw virtio-scsi-single \
        --ostype l26 \
        --agent 1

    qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"
    qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,cache=none,discard=on,ssd=1,iothread=1"
    qm resize "$VMID" scsi0 "$DISK_SIZE"

    # cloud-init 盘固定挂在 scsi2
    qm set "$VMID" --scsi2 "${STORAGE}:cloudinit"
    qm set "$VMID" --boot order=scsi0
    qm set "$VMID" --serial0 socket --vga serial0

    log_step "转换为模板"
    qm template "$VMID"

    log_info "模板创建成功: $VMID"
}

main() {
    parse_args "$@"
    check_dependencies
    detect_storage
    resolve_urls
    resolve_remote_sha256

    log_info "========================================"
    log_info "PVE 模板创建"
    log_info "OS: $OS"
    log_info "ARCH: $ARCH"
    log_info "VMID: $VMID"
    log_info "Storage: $STORAGE"
    log_info "Bridge: $BRIDGE"
    log_info "Memory: ${MEMORY}MB"
    log_info "Cores: $CORES"
    log_info "Disk: $DISK_SIZE"
    log_info "Image URL: $RESOLVED_IMAGE_URL"
    if [ -n "$IMAGE_URL" ]; then
        log_info "Source: custom image-url"
    else
        log_info "Repo: $GH_REPO"
        log_info "Release: ${RELEASE_TAG:-$RELEASE}"
    fi
    log_info "========================================"

    download_image
    create_vm_template

    log_info "完成"
}

main "$@"
