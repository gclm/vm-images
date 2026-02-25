#!/bin/bash
set -e

# generate-cloud-init.sh - 生成 cloud-init 配置 ISO
#
# 用法:
#   ./generate-cloud-init.sh <config_name> [output_dir]
#   ./generate-cloud-init.sh debian12
#   ./generate-cloud-init.sh debian12 ./output
#
# 环境变量:
#   SSH_PUBLIC_KEY - SSH 公钥 (必填)
#   ROOT_PASSWORD  - root 密码 (必填)
#
# 输出:
#   <output_dir>/<name>-cloudinit.iso - cloud-init ISO 文件

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${2:-${PROJECT_DIR}/output}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查参数
if [ -z "$1" ]; then
    log_error "请指定镜像配置，例如: debian12"
    echo "可用配置:"
    find "${PROJECT_DIR}/images" -name "config.yaml" -exec dirname {} \; | xargs -I {} basename {} | sort -u | sed 's/^/  - /'
    exit 1
fi

IMAGE_NAME="$1"
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
    command -v genisoimage &> /dev/null || command -v mkisofs &> /dev/null || missing+=("genisoimage/mkisofs")
    command -v yq &> /dev/null || missing+=("yq")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少工具: ${missing[*]}"
        echo "安装命令:"
        echo "  sudo apt install genisoformat"
        echo "  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
        exit 1
    fi
}

# 读取配置
read_config() {
    local config_file="$1"
    NAME=$(yq '.name' "$config_file")
    TIMEZONE=$(yq '.settings.timezone' "$config_file")
    HOSTNAME=$(yq '.settings.hostname' "$config_file")

    # 获取非 root 用户
    FIRST_USER=$(yq '.users[] | select(.name != "root") | .name' "$config_file" | head -1)

    # 获取软件包列表
    PACKAGES=$(yq '.packages[]' "$config_file" | tr '\n' ',' | sed 's/,$//')

    # 获取文件配置
    FILES_JSON=$(yq -o=json '.files' "$config_file")

    # 获取命令列表
    COMMANDS=$(yq '.commands[]' "$config_file")

    # 获取 APT mirror
    APT_MIRROR=$(yq '.apt.mirror' "$config_file")
}

# 生成 user-data 文件
generate_user_data() {
    local output_file="$1"

    log_info "生成 user-data 文件..."

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

    # 禁用 root SSH 登录或允许
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

    log_info "user-data 文件已生成: $output_file"
}

# 生成 meta-data 文件
generate_meta_data() {
    local output_file="$1"
    local instance_id="$2"

    log_info "生成 meta-data 文件..."

    cat > "$output_file" << EOF
instance-id: $instance_id
local-hostname: ${HOSTNAME:-cloud-instance}
EOF

    log_info "meta-data 文件已生成: $output_file"
}

# 生成 network-config 文件 (可选)
generate_network_config() {
    local output_file="$1"

    log_info "生成 network-config 文件..."

    cat > "$output_file" << 'EOF'
version: 2
ethernets:
  id0:
    match:
      driver: virtio*
    dhcp4: true
    dhcp6: false
EOF

    log_info "network-config 文件已生成: $output_file"
}

# 生成 ISO 文件
generate_iso() {
    local cidata_dir="$1"
    local output_iso="$2"

    log_info "生成 cloud-init ISO: $output_iso"

    # 使用 genisoimage 或 mkisofs
    if command -v genisoimage &> /dev/null; then
        genisoimage -output "$output_iso" -volid cidata -joliet -rock "$cidata_dir"
    else
        mkisofs -output "$output_iso" -volid cidata -joliet -rock "$cidata_dir"
    fi

    log_info "ISO 文件已生成: $output_iso"
    ls -lh "$output_iso"
}

# 主流程
main() {
    check_tools

    log_info "========================================"
    log_info "生成 cloud-init 配置: ${IMAGE_NAME}"
    log_info "========================================"

    # 读取配置
    read_config "$CONFIG_PATH"

    log_info "镜像名称: $NAME"
    log_info "主机名: $HOSTNAME"
    log_info "时区: $TIMEZONE"
    log_info "用户: $FIRST_USER"

    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"

    # 创建临时目录
    local cidata_dir=$(mktemp -d)
    trap "rm -rf $cidata_dir" EXIT

    # 生成实例 ID
    local instance_id="${NAME}-$(date +%Y%m%d%H%M%S)"

    # 生成配置文件
    generate_user_data "${cidata_dir}/user-data"
    generate_meta_data "${cidata_dir}/meta-data" "$instance_id"
    generate_network_config "${cidata_dir}/network-config"

    # 生成 ISO
    local output_iso="${OUTPUT_DIR}/${NAME}-cloudinit.iso"
    generate_iso "$cidata_dir" "$output_iso"

    # 生成校验和
    log_info "生成校验和..."
    sha256sum "$output_iso" > "${output_iso}.sha256"

    log_info "========================================"
    log_info "生成成功!"
    log_info "输出文件: $output_iso"
    log_info "校验文件: ${output_iso}.sha256"
    log_info "========================================"
    log_info ""
    log_info "使用方法:"
    log_info "  qemu-system-x86_64 -m 1024 -smp 2 \\"
    log_info "    -drive file=<镜像文件>,format=qcow2 \\"
    log_info "    -cdrom $output_iso \\"
    log_info "    -netdev user,id=net0 -device virtio-net-pci,netdev=net0"
}

main
