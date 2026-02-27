#!/bin/bash
set -euo pipefail

# pve-create-template.sh - 在 PVE 上创建 cloud-init 模板（不启动模板）
#
# 用法:
#   ./pve-create-template.sh <os> <arch> <vmid> [options]
#
# 设计原则:
#   - 模板阶段不启动 VM
#   - 模板中不固化账号/密码
#   - 克隆实例后在 PVE GUI 中配置 ciuser/sshkeys/ipconfig0

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
CI_USER="root"
CI_PASSWORD=""
CI_SSHKEY_FILE=""
CI_SSHKEY_TEXT=""
RESOLVED_SSHKEY_FILE=""
CI_CUSTOM=""
CI_UPGRADE=true
NO_TEMPLATE=false
SKIP_DOWNLOAD=false

RELEASE="latest"
GH_REPO="${GH_REPO:-gclm/vm-images}"
IMAGE_URL=""

USE_PROXY=false
PROXY_URL="${PROXY_URL:-https://proxy.991201.xyz/}"

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
  --ciuser USER      cloud-init 用户名 (默认: root)
  --cipassword PASS  cloud-init 密码 (可选)
  --sshkey-file FILE SSH 公钥文件路径
  --sshkey KEY       SSH 公钥内容（单行）
  --cicustom CONFIG  自定义 cloud-init 配置 (格式: user=local:snippets/file.yaml)
  --ciupgrade        升级系统包 (默认: true)
  --no-ciupgrade     不升级系统包
  --release TAG      GitHub Release 标签 (默认: latest)
  --repo OWNER/REPO  GitHub 仓库 (默认: gclm/vm-images)
  --image-url URL    直接指定 qcow2 下载地址（优先级最高）
  --no-template      创建 VM 但不转换为模板
  --skip-download    跳过下载，使用 /tmp 中已有镜像
  --proxy            启用代理下载
  --proxy-url URL    自定义代理地址

示例:
  $0 debian13 amd64 9011 --storage hdd-pool --release v1.0.0
  $0 ubuntu2404 amd64 9012 --repo yourorg/vm-images --release v2.0.0
  $0 debian13 amd64 9013 --image-url https://example.com/debian13-amd64.qcow2
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
            --ciuser) CI_USER="$2"; shift 2 ;;
            --cipassword) CI_PASSWORD="$2"; shift 2 ;;
            --sshkey-file) CI_SSHKEY_FILE="$2"; shift 2 ;;
            --sshkey) CI_SSHKEY_TEXT="$2"; shift 2 ;;
            --cicustom) CI_CUSTOM="$2"; shift 2 ;;
            --ciupgrade) CI_UPGRADE=true; shift ;;
            --no-ciupgrade) CI_UPGRADE=false; shift ;;
            --release) RELEASE="$2"; shift 2 ;;
            --repo) GH_REPO="$2"; shift 2 ;;
            --image-url) IMAGE_URL="$2"; shift 2 ;;
            --no-template) NO_TEMPLATE=true; shift ;;
            --skip-download) SKIP_DOWNLOAD=true; shift ;;
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

    if [ -n "$CI_CUSTOM" ] && [ -n "$CI_PASSWORD" ]; then
        log_warn "同时设置 --cicustom 与 --cipassword，密码可能被自定义 user-data 覆盖"
    fi

    if [ -n "$CI_CUSTOM" ] && { [ -n "$CI_SSHKEY_FILE" ] || [ -n "$CI_SSHKEY_TEXT" ]; }; then
        log_warn "同时设置 --cicustom 与 --sshkey，SSH key 可能被自定义 user-data 覆盖"
    fi
}

check_dependencies() {
    local missing=()
    command -v qm >/dev/null 2>&1 || missing+=("qm")
    command -v pvesm >/dev/null 2>&1 || missing+=("pvesm")
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

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
        echo "${PROXY_URL}${url}"
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

resolve_ssh_key() {
    if [ -n "$CI_SSHKEY_FILE" ] && [ -n "$CI_SSHKEY_TEXT" ]; then
        log_error "--sshkey-file 和 --sshkey 不能同时使用"
        exit 1
    fi

    if [ -n "$CI_SSHKEY_TEXT" ]; then
        RESOLVED_SSHKEY_FILE="/tmp/pve-sshkey-${VMID}.pub"
        printf '%s\n' "$CI_SSHKEY_TEXT" > "$RESOLVED_SSHKEY_FILE"
        return
    fi

    if [ -n "$CI_SSHKEY_FILE" ]; then
        if [ ! -s "$CI_SSHKEY_FILE" ]; then
            log_error "SSH 公钥文件不存在或为空: $CI_SSHKEY_FILE"
            exit 1
        fi
        RESOLVED_SSHKEY_FILE="$CI_SSHKEY_FILE"
        return
    fi

    local candidates=(
        "${HOME}/.ssh/id_ed25519.pub"
        "${HOME}/.ssh/id_rsa.pub"
        "${HOME}/.ssh/authorized_keys"
    )

    local key_file
    for key_file in "${candidates[@]}"; do
        if [ -s "$key_file" ]; then
            RESOLVED_SSHKEY_FILE="$key_file"
            log_info "自动检测 SSH key: $RESOLVED_SSHKEY_FILE"
            return
        fi
    done

    if [ -z "$CI_PASSWORD" ]; then
        log_warn "未提供 SSH key 且未设置密码，首次登录可能失败"
    fi
}

download_image() {
    local image_name="${IMAGE_NAMES[$OS]}"
    local image_file="/tmp/${image_name}-${ARCH}.qcow2"

    if [ "$SKIP_DOWNLOAD" = true ] && [ -f "$image_file" ]; then
        IMAGE_FILE="$image_file"
        log_info "跳过下载，使用已有镜像: $IMAGE_FILE"
        return
    fi

    local url
    if [ -n "$IMAGE_URL" ]; then
        url="$IMAGE_URL"
    else
        resolve_release_tag
        url="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${image_name}-${ARCH}.qcow2"
    fi

    url=$(apply_proxy "$url")

    log_step "下载 qcow2 镜像"
    log_info "URL: $url"

    wget -q --show-progress "$url" -O "${image_file}.tmp"
    mv "${image_file}.tmp" "$image_file"
    IMAGE_FILE="$image_file"
}

create_vm() {
    local image_name="${IMAGE_NAMES[$OS]}"

    if qm status "$VMID" >/dev/null 2>&1; then
        log_error "VMID 已存在: $VMID"
        exit 1
    fi

    log_step "创建 VM: $VMID"

    local ci_args=(
        --name "${image_name}-${ARCH}"
        --memory "$MEMORY"
        --cores "$CORES"
        --cpu host
        --net0 "virtio,bridge=${BRIDGE}"
        --scsihw virtio-scsi-single
        --ostype l26
        --agent 1
        --ciuser "$CI_USER"
    )

    if [ -n "$CI_PASSWORD" ]; then
        ci_args+=(--cipassword "$CI_PASSWORD")
    fi
    if [ -n "$RESOLVED_SSHKEY_FILE" ]; then
        ci_args+=(--sshkeys "$RESOLVED_SSHKEY_FILE")
    fi
    if [ -n "$CI_CUSTOM" ]; then
        ci_args+=(--cicustom "$CI_CUSTOM")
    fi
    if [ "$CI_UPGRADE" = true ]; then
        ci_args+=(--ciupgrade 1)
    fi

    qm create "$VMID" "${ci_args[@]}"
    qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"
    qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
    qm resize "$VMID" scsi0 "$DISK_SIZE"

    # 按文档建议使用 scsi2 作为 cloud-init 盘
    qm set "$VMID" --scsi2 "${STORAGE}:cloudinit"
    qm set "$VMID" --boot order=scsi0
    qm set "$VMID" --serial0 socket --vga serial0

    log_info "VM 创建完成: $VMID"
}

convert_to_template() {
    if [ "$NO_TEMPLATE" = true ]; then
        log_info "跳过模板转换 (--no-template)"
        return
    fi

    log_step "转换为模板（不启动 VM）"
    qm template "$VMID"
    log_info "模板创建成功: $VMID"
}

main() {
    parse_args "$@"
    check_dependencies
    detect_storage
    resolve_ssh_key

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
    log_info "Repo: $GH_REPO"
    log_info "Release: $RELEASE"
    if [ -n "$CI_CUSTOM" ]; then
        log_info "cicustom: $CI_CUSTOM"
    fi
    if [ -n "$RESOLVED_SSHKEY_FILE" ]; then
        log_info "ssh key: $RESOLVED_SSHKEY_FILE"
    else
        log_warn "ssh key: 未设置"
    fi
    log_info "========================================"

    download_image
    create_vm
    convert_to_template

    log_info "完成"
    if [ "$NO_TEMPLATE" = false ]; then
        log_info "下一步: 在 PVE GUI 克隆模板后配置 Cloud-Init（ciuser/sshkeys/ipconfig0）"
    fi
}

main "$@"
