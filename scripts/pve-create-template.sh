#!/bin/bash
set -e

# pve-create-template.sh - PVE 一键创建 VM 模板
#
# 用法:
#   ./pve-create-template.sh <os> <arch> <vmid> [options]
#   ./pve-create-template.sh debian12 amd64 9000
#   ./pve-create-template.sh debian12 amd64 9000 --storage local-lvm
#   ./pve-create-template.sh ubuntu2404 arm64 9001 --bridge vmbr1
#
# 参数:
#   os      - 操作系统名称 (debian12, debian13, ubuntu2204, ubuntu2404, rocky10)
#   arch    - 架构 (amd64, arm64)
#   vmid    - VM ID (数字)
#
# 选项:
#   --storage      存储名称 (默认: local-lvm)
#   --bridge       网桥名称 (默认: vmbr0)
#   --memory       内存 MB (默认: 2048)
#   --cores        CPU 核心数 (默认: 2)
#   --disk-size    磁盘大小 (默认: 10G)
#   --release      GitHub Release 版本 (默认: latest)
#   --no-template  创建 VM 但不转换为模板
#   --skip-download 跳过下载，使用已有文件
#
# 环境变量:
#   GITHUB_REPO   - GitHub 仓库 (默认: gclm/vm-images)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 默认配置
STORAGE="local-lvm"
BRIDGE="vmbr0"
MEMORY=2048
CORES=2
DISK_SIZE="10G"
RELEASE="latest"
NO_TEMPLATE=false
SKIP_DOWNLOAD=false
GITHUB_REPO="${GITHUB_REPO:-gclm/vm-images}"

# 镜像配置 (名称: URL 模板)
declare -A IMAGE_URLS=(
    ["debian12:amd64"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    ["debian12:arm64"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"
    ["debian13:amd64"]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    ["debian13:arm64"]="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2"
    ["ubuntu2204:amd64"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ["ubuntu2204:arm64"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
    ["ubuntu2404:amd64"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ["ubuntu2404:arm64"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
    ["rocky10:amd64"]="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
    ["rocky10:arm64"]="https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2"
)

# 镜像名称映射
declare -A IMAGE_NAMES=(
    ["debian12"]="debian12"
    ["debian13"]="debian13"
    ["ubuntu2204"]="ubuntu2204"
    ["ubuntu2404"]="ubuntu2404"
    ["rocky10"]="rocky10"
)

# 显示帮助
show_help() {
    cat << EOF
用法: $0 <os> <arch> <vmid> [options]

参数:
  os      - 操作系统 (debian12, debian13, ubuntu2204, ubuntu2404, rocky10)
  arch    - 架构 (amd64, arm64)
  vmid    - VM ID (数字)

选项:
  --storage NAME      存储名称 (默认: local-lvm)
  --bridge NAME       网桥名称 (默认: vmbr0)
  --memory MB         内存大小 (默认: 2048)
  --cores N           CPU 核心数 (默认: 2)
  --disk-size SIZE    磁盘大小 (默认: 10G)
  --release VERSION   GitHub Release 版本 (默认: latest)
  --no-template       创建 VM 但不转换为模板
  --skip-download     跳过下载，使用已有文件

示例:
  $0 debian12 amd64 9000
  $0 ubuntu2404 amd64 9001 --storage local-zfs --memory 4096
  $0 rocky10 arm64 9002 --bridge vmbr1 --cores 4
EOF
    exit 0
}

# 解析参数
parse_args() {
    if [ $# -lt 3 ]; then
        show_help
    fi

    OS="$1"
    ARCH="$2"
    VMID="$3"
    shift 3

    # 验证参数
    if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
        log_error "VMID 必须是数字: $VMID"
        exit 1
    fi

    # 解析选项
    while [ $# -gt 0 ]; do
        case "$1" in
            --storage) STORAGE="$2"; shift 2 ;;
            --bridge) BRIDGE="$2"; shift 2 ;;
            --memory) MEMORY="$2"; shift 2 ;;
            --cores) CORES="$2"; shift 2 ;;
            --disk-size) DISK_SIZE="$2"; shift 2 ;;
            --release) RELEASE="$2"; shift 2 ;;
            --no-template) NO_TEMPLATE=true; shift ;;
            --skip-download) SKIP_DOWNLOAD=true; shift ;;
            -h|--help) show_help ;;
            *) log_error "未知选项: $1"; exit 1 ;;
        esac
    done

    # 验证操作系统
    if [ -z "${IMAGE_NAMES[$OS]}" ]; then
        log_error "不支持的操作系统: $OS"
        echo "支持: ${!IMAGE_NAMES[*]}"
        exit 1
    fi

    # 验证架构
    if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
        log_error "不支持的架构: $ARCH (支持: amd64, arm64)"
        exit 1
    fi
}

# 检查是否在 PVE 环境运行
check_pve() {
    if [ ! -f /etc/pve/.vmlist ]; then
        log_error "此脚本必须在 Proxmox VE 环境中运行"
        exit 1
    fi

    if ! command -v qm &> /dev/null; then
        log_error "找不到 qm 命令"
        exit 1
    fi
}

# 下载官方镜像
download_image() {
    local url="${IMAGE_URLS[$OS:$ARCH]}"
    local image_name="${IMAGE_NAMES[$OS]}"
    local image_file="/tmp/${image_name}-${ARCH}.qcow2"

    if [ "$SKIP_DOWNLOAD" = true ] && [ -f "$image_file" ]; then
        log_info "使用已有镜像: $image_file"
        return
    fi

    log_step "下载官方镜像: $url"

    if [ -f "$image_file" ]; then
        log_info "镜像已存在: $image_file"
    else
        wget -q --show-progress "$url" -O "$image_file.tmp"
        mv "$image_file.tmp" "$image_file"
    fi

    IMAGE_FILE="$image_file"
}

# 下载 cloud-init ISO
download_cloudinit() {
    local image_name="${IMAGE_NAMES[$OS]}"
    local iso_file="/tmp/${image_name}-cloudinit.iso"

    if [ "$SKIP_DOWNLOAD" = true ] && [ -f "$iso_file" ]; then
        log_info "使用已有 cloud-init ISO: $iso_file"
        CLOUDINIT_FILE="$iso_file"
        return
    fi

    log_step "下载 cloud-init ISO"

    # 获取下载 URL
    local download_url
    if [ "$RELEASE" = "latest" ]; then
        download_url=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | \
            jq -r --arg name "$image_name" '.assets[] | select(.name == "\($name)-cloudinit.iso") | .browser_download_url')
    else
        download_url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE}/${image_name}-cloudinit.iso"
    fi

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        log_error "找不到 cloud-init ISO 下载链接"
        log_info "请确保已发布 Release 并包含 ${image_name}-cloudinit.iso"
        exit 1
    fi

    log_info "下载地址: $download_url"

    if [ -f "$iso_file" ]; then
        log_info "ISO 已存在: $iso_file"
    else
        wget -q --show-progress "$download_url" -O "$iso_file.tmp"
        mv "$iso_file.tmp" "$iso_file"
    fi

    CLOUDINIT_FILE="$iso_file"
}

# 创建 VM
create_vm() {
    local image_name="${IMAGE_NAMES[$OS]}"

    log_step "创建 VM: $VMID"

    # 检查 VMID 是否已存在
    if qm status "$VMID" &> /dev/null; then
        log_error "VMID $VMID 已存在"
        exit 1
    fi

    # 创建 VM
    qm create "$VMID" \
        --name "${image_name}-${ARCH}" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --cpu host \
        --net0 virtio,bridge="$BRIDGE" \
        --scsihw virtio-scsi-pci \
        --ostype l26

    log_info "VM $VMID 已创建"

    # 导入磁盘
    log_step "导入磁盘镜像"
    qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"

    # 获取导入的磁盘 ID
    local disk_id=$(qm config "$VMID" | grep unused | cut -d: -f1 | cut -d, -f2 | head -1)
    if [ -z "$disk_id" ]; then
        # 尝试另一种方式获取
        disk_id=$(ls -1 /dev/${STORAGE}/vm-${VMID}-disk-* 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")
    fi

    # 挂载磁盘
    log_step "配置磁盘"
    qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

    # 调整磁盘大小
    local current_size=$(qm config "$VMID" | grep scsi0 | grep -oP 'size=\K[^,]+')
    log_info "当前磁盘大小: $current_size, 扩展到: $DISK_SIZE"
    qm resize "$VMID" scsi0 "$DISK_SIZE"

    # 挂载 cloud-init ISO
    log_step "挂载 cloud-init ISO"
    qm set "$VMID" --ide2 "$CLOUDINIT_FILE",media=cdrom

    # 设置启动顺序
    qm set "$VMID" --boot c --bootdisk scsi0

    # 启用 QEMU Guest Agent
    qm set "$VMID" --agent 1

    log_info "VM $VMID 配置完成"
}

# 转换为模板
convert_to_template() {
    if [ "$NO_TEMPLATE" = true ]; then
        log_info "跳过模板转换 (--no-template)"
        return
    fi

    log_step "转换为模板"

    # 先启动一次让 cloud-init 完成配置
    log_info "启动 VM 等待 cloud-init 配置完成..."
    qm start "$VMID"

    # 等待 VM 关闭或超时
    log_info "等待 cloud-init 完成 (约 2-3 分钟)..."
    log_warn "请手动 SSH 检查配置是否完成，然后执行:"
    echo "  qm shutdown $VMID"
    echo "  qm template $VMID"
    echo ""
    echo "或者直接执行以下命令自动完成:"
    echo "  sleep 180 && qm shutdown $VMID && qm template $VMID"

    # 询问是否继续
    read -p "是否立即关闭并转换为模板? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "等待 60 秒后关闭..."
        sleep 60
        qm shutdown "$VMID" || true
        sleep 10
        qm template "$VMID"
        log_info "模板创建成功: $VMID"
    fi
}

# 清理临时文件
cleanup() {
    if [ -n "$IMAGE_FILE" ] && [ -f "$IMAGE_FILE" ]; then
        log_info "保留镜像文件: $IMAGE_FILE (可复用)"
    fi
    if [ -n "$CLOUDINIT_FILE" ] && [ -f "$CLOUDINIT_FILE" ]; then
        log_info "保留 cloud-init ISO: $CLOUDINIT_FILE (可复用)"
    fi
}

# 主流程
main() {
    parse_args "$@"

    log_info "========================================"
    log_info "PVE VM 模板创建工具"
    log_info "========================================"
    log_info "操作系统: $OS"
    log_info "架构: $ARCH"
    log_info "VM ID: $VMID"
    log_info "存储: $STORAGE"
    log_info "网桥: $BRIDGE"
    log_info "内存: ${MEMORY}MB"
    log_info "CPU: ${CORES} 核"
    log_info "磁盘: $DISK_SIZE"
    log_info "========================================"

    check_pve
    download_image
    download_cloudinit
    create_vm
    convert_to_template
    cleanup

    log_info "========================================"
    log_info "完成!"
    log_info "========================================"
}

main "$@"
