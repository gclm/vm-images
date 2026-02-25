#!/bin/bash
set -e

# build-with-cloudinit.sh - 使用 cloud-init 方式构建 VM 镜像
#
# 这个脚本不需要 libguestfs，只需要下载官方 cloud 镜像并生成 cloud-init ISO
#
# 用法:
#   ./build-with-cloudinit.sh <os> [arch]
#   ./build-with-cloudinit.sh debian12          # 默认 amd64
#   ./build-with-cloudinit.sh debian12 amd64
#   ./build-with-cloudinit.sh debian12 arm64
#
# 环境变量:
#   SSH_PUBLIC_KEY - SSH 公钥 (必填)
#   ROOT_PASSWORD  - root 密码 (必填)
#   OUTPUT_DIR     - 输出目录 (默认: ./output)
#
# 输出:
#   <output_dir>/<name>-<arch>.qcow2       - 虚拟机镜像
#   <output_dir>/<name>-cloudinit.iso      - cloud-init 配置 ISO

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"

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
    command -v wget &> /dev/null || missing+=("wget")
    command -v yq &> /dev/null || missing+=("yq")
    command -v genisoimage &> /dev/null || command -v mkisofs &> /dev/null || missing+=("genisoimage")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少工具: ${missing[*]}"
        echo "安装命令:"
        echo "  sudo apt install qemu-utils wget genisoimage"
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

    if [ "$SOURCE_URL" = "null" ] || [ -z "$SOURCE_URL" ]; then
        log_error "配置文件中未找到架构 ${arch} 的镜像 URL"
        exit 1
    fi

    # 获取非 root 用户
    FIRST_USER=$(yq '.users[] | select(.name != "root") | .name' "$config_file" | head -1)

    # 获取软件包列表
    PACKAGES=$(yq '.packages[]' "$config_file" | tr '\n' ',' | sed 's/,$//')

    # 获取文件配置 (JSON 格式)
    FILES_JSON=$(yq -o=json '.files' "$config_file")

    # 获取命令列表
    COMMANDS=$(yq '.commands[]' "$config_file")
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

# 生成 user-data 文件
generate_user_data() {
    local output_file="$1"

    log_step "生成 user-data 文件..."

    # 开始构建 user-data
    cat > "$output_file" << 'USERDATA_HEADER'
#cloud-config
USERDATA_HEADER

    # 设置主机名
    if [ -n "$HOSTNAME" ] && [ "$HOSTNAME" != "null" ]; then
        echo "hostname: $HOSTNAME" >> "$output_file"
        echo "manage_etc_hosts: true" >> "$output_file"
    fi

    # 设置时区
    if [ -n "$TIMEZONE" ] && [ "$TIMEZONE" != "null" ]; then
        echo "timezone: $TIMEZONE" >> "$output_file"
    fi

    # 创建用户
    echo "users:" >> "$output_file"
    echo "  - name: root" >> "$output_file"
    echo "    lock_passwd: false" >> "$output_file"
    echo "    hashed_passwd: $(echo "$ROOT_PASSWORD" | openssl passwd -6 -stdin)" >> "$output_file"

    if [ -n "$FIRST_USER" ] && [ "$FIRST_USER" != "null" ]; then
        echo "  - name: $FIRST_USER" >> "$output_file"
        echo "    sudo: ALL=(ALL) NOPASSWD:ALL" >> "$output_file"
        echo "    shell: /bin/bash" >> "$output_file"
        echo "    lock_passwd: false" >> "$output_file"
        echo "    hashed_passwd: $(echo "$ROOT_PASSWORD" | openssl passwd -6 -stdin)" >> "$output_file"
        echo "    ssh_authorized_keys:" >> "$output_file"
        echo "      - $SSH_PUBLIC_KEY" >> "$output_file"
    fi

    # SSH 配置
    echo "ssh_pwauth: true" >> "$output_file"
    echo "disable_root: false" >> "$output_file"

    # 安装软件包
    if [ -n "$PACKAGES" ] && [ "$PACKAGES" != "null" ]; then
        echo "packages:" >> "$output_file"
        echo "$PACKAGES" | tr ',' '\n' | while read pkg; do
            if [ -n "$pkg" ]; then
                echo "  - $pkg" >> "$output_file"
            fi
        done
    fi

    # 写入文件
    if [ -n "$FILES_JSON" ] && [ "$FILES_JSON" != "null" ] && [ "$FILES_JSON" != "[]" ]; then
        echo "write_files:" >> "$output_file"
        local file_count=$(echo "$FILES_JSON" | jq 'length')
        for ((i=0; i<file_count; i++)); do
            local file_path=$(echo "$FILES_JSON" | jq -r ".[$i].path")
            local file_content=$(echo "$FILES_JSON" | jq -r ".[$i].content")
            local file_perm=$(echo "$FILES_JSON" | jq -r ".[$i].permissions // \"0644\"")

            echo "  - path: $file_path" >> "$output_file"
            echo "    permissions: '$file_perm'" >> "$output_file"
            echo "    content: |" >> "$output_file"
            echo "$file_content" | while IFS= read -r line; do
                echo "      $line" >> "$output_file"
            done
        done
    fi

    # 运行命令
    if [ -n "$COMMANDS" ] && [ "$COMMANDS" != "null" ]; then
        echo "runcmd:" >> "$output_file"
        while IFS= read -r cmd; do
            if [ -n "$cmd" ]; then
                echo "  - $cmd" >> "$output_file"
            fi
        done <<< "$COMMANDS"
    fi

    # APT 镜像源配置 (Debian)
    if [ -n "$APT_MIRROR" ] && [ "$APT_MIRROR" != "null" ]; then
        cat >> "$output_file" << MIRROR_EOF

apt:
  primary:
    - arches: [default]
      uri: $APT_MIRROR
  security:
    - arches: [default]
      uri: ${APT_MIRROR}-security
MIRROR_EOF
    fi

    log_info "user-data 已生成"
}

# 生成 meta-data 文件
generate_meta_data() {
    local output_file="$1"
    local instance_id="$2"

    log_step "生成 meta-data 文件..."

    cat > "$output_file" << EOF
instance-id: $instance_id
local-hostname: ${HOSTNAME:-cloud-instance}
EOF

    log_info "meta-data 已生成"
}

# 生成 network-config 文件
generate_network_config() {
    local output_file="$1"

    log_step "生成 network-config 文件..."

    cat > "$output_file" << 'EOF'
version: 2
ethernets:
  id0:
    match:
      driver: virtio*
    dhcp4: true
    dhcp6: false
EOF

    log_info "network-config 已生成"
}

# 生成 cloud-init ISO
generate_cloudinit_iso() {
    local cidata_dir="$1"
    local output_iso="$2"

    log_step "生成 cloud-init ISO..."

    if command -v genisoimage &> /dev/null; then
        genisoimage -quiet -output "$output_iso" -volid cidata -joliet -rock "$cidata_dir"
    else
        mkisofs -quiet -output "$output_iso" -volid cidata -joliet -rock "$cidata_dir"
    fi

    log_info "cloud-init ISO 已生成"
}

# 主流程
main() {
    check_tools

    log_info "========================================"
    log_info "开始构建: ${IMAGE_NAME} (${ARCH})"
    log_info "========================================"

    # 读取配置
    read_config "$CONFIG_PATH" "$ARCH"

    log_info "镜像名称: $NAME"
    log_info "版本: $VERSION"
    log_info "架构: $ARCH"
    log_info "主机名: $HOSTNAME"
    log_info "用户: $FIRST_USER"

    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    mkdir -p "${PROJECT_DIR}/.cache"

    # 1. 下载源镜像
    log_step "步骤 1/4: 下载源镜像"
    local source_file="${PROJECT_DIR}/.cache/$(basename "$SOURCE_URL")"
    download_source "$SOURCE_URL" "$source_file"

    # 2. 复制并扩展镜像
    log_step "步骤 2/4: 准备镜像"
    local output_file="${OUTPUT_DIR}/${NAME}-${ARCH}.qcow2"
    cp "$source_file" "$output_file"
    qemu-img resize "$output_file" "$DISK_SIZE"
    log_info "镜像大小已扩展到: $DISK_SIZE"

    # 3. 生成 cloud-init ISO
    log_step "步骤 3/4: 生成 cloud-init 配置"
    local cidata_dir=$(mktemp -d)
    local instance_id="${NAME}-${ARCH}-$(date +%Y%m%d%H%M%S)"

    generate_user_data "${cidata_dir}/user-data"
    generate_meta_data "${cidata_dir}/meta-data" "$instance_id"
    generate_network_config "${cidata_dir}/network-config"

    local cloudinit_iso="${OUTPUT_DIR}/${NAME}-cloudinit.iso"
    generate_cloudinit_iso "$cidata_dir" "$cloudinit_iso"

    rm -rf "$cidata_dir"

    # 4. 生成校验和
    log_step "步骤 4/4: 生成校验和"
    sha256sum "$output_file" > "${output_file}.sha256"
    sha256sum "$cloudinit_iso" > "${cloudinit_iso}.sha256"

    # 输出结果
    log_info "========================================"
    log_info "构建成功!"
    log_info "========================================"
    echo ""
    echo "输出文件:"
    ls -lh "$output_file"
    ls -lh "$cloudinit_iso"
    echo ""
    echo "使用方法:"
    echo "  # 使用 QEMU 启动"
    echo "  qemu-system-x86_64 -m 1024 -smp 2 \\"
    echo "    -drive file=${output_file},format=qcow2 \\"
    echo "    -cdrom ${cloudinit_iso} \\"
    echo "    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \\"
    echo "    -nographic"
    echo ""
    echo "  # 使用 Proxmox VE"
    echo "  1. 上传 ${output_file} 到 PVE 存储"
    echo "  2. 上传 ${cloudinit_iso} 到 ISO 存储"
    echo "  3. 创建 VM，使用该磁盘镜像"
    echo "  4. 挂载 cloud-init ISO 为 CD-ROM"
    echo "  5. 启动 VM"
    echo ""
    echo "  # 使用 Libvirt/Virsh"
    echo "  virt-install --name ${NAME}-${ARCH} \\"
    echo "    --memory 1024 --vcpus 2 \\"
    echo "    --disk path=${output_file},format=qcow2 \\"
    echo "    --cdrom ${cloudinit_iso} \\"
    echo "    --network network=default \\"
    echo "    --graphics none --console pty,target_type=serial"
}

main
