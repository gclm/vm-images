# VM 基础镜像构建工具

为 PVE (Proxmox VE) 快速部署预配置的虚拟机基础镜像。

## 支持的镜像

| 操作系统 | 镜像名称 | 默认用户 | amd64 | arm64 |
|:---|:---|:---:|:---:|:---:|
| Debian 12 (Bookworm) | `debian12` | `debian` | ✅ | ✅ |
| Debian 13 (Trixie) | `debian13` | `debian` | ✅ | ✅ |
| Ubuntu 22.04 (Jammy) | `ubuntu2204` | `ubuntu` | ✅ | ✅ |
| Ubuntu 24.04 (Noble) | `ubuntu2404` | `ubuntu` | ✅ | ✅ |
| Rocky Linux 10 | `rocky10` | `rocky` | ✅ | ✅ |

## 预装软件

所有镜像预装以下常用工具：

| 类别 | 软件包 |
|:---|:---|
| 基础工具 | vim, curl, wget, git |
| 系统工具 | htop, tmux, net-tools, lsof |
| 网络工具 | socat, netcat, ethtool, iptables |
| 实用工具 | jq, tree, bash-completion |
| 云工具 | qemu-guest-agent, cloud-guest-utils |

## 系统配置

所有镜像预配置以下 sysctl 参数：

```bash
net.ipv4.ip_forward=0
net.ipv6.conf.all.disable_ipv6=1
fs.inotify.max_user_instances=512
fs.inotify.max_user_watches=262144
```

## 快速开始

### 1. 配置环境变量

```bash
cp .env.example .env
vim .env
```

### 2. 本地构建

#### 方式一：Cloud-Init 方式 (推荐)

不需要 libguestfs，CI 环境友好，配置在 VM 启动时应用。

```bash
# 安装工具
sudo apt install qemu-utils wget genisoimage openssl

# 安装 yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# 构建镜像 + cloud-init ISO
./scripts/build-with-cloudinit.sh debian12           # amd64 (默认)
./scripts/build-with-cloudinit.sh debian12 amd64     # amd64
./scripts/build-with-cloudinit.sh debian12 arm64     # arm64
```

#### 方式二：virt-customize 方式 (需要 libguestfs)

直接修改镜像，需要 Linux 环境和 KVM 支持。

```bash
# 安装工具
sudo apt install qemu-utils libguestfs-tools wget

# 安装 yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# 构建镜像
./scripts/build-image.sh debian12           # amd64 (默认)
./scripts/build-image.sh debian12 amd64     # amd64
./scripts/build-image.sh debian12 arm64     # arm64
```

### 3. GitHub Actions 构建

在仓库设置中配置 Secrets：

| Secret | 说明 |
|:---|:---|
| `SSH_PUBLIC_KEY` | SSH 公钥 |
| `ROOT_PASSWORD` | root 密码 |

有两种工作流可选：

| 工作流 | 文件 | 说明 |
|:---|:---|:---|
| Cloud-Init (推荐) | `build-cloudinit.yml` | 不需要 libguestfs，CI 友好 |
| virt-customize | `build-images.yml` | 需要跳过软件包安装 |

触发方式：
- Push 到 main 分支自动构建
- 手动触发指定镜像和架构
- 创建 tag 发布 release

## 目录结构

```
iso/
├── .env.example
├── .github/workflows/
│   ├── build-cloudinit.yml         # Cloud-Init 工作流 (推荐)
│   └── build-images.yml            # virt-customize 工作流
├── images/
│   ├── debian12/config.yaml
│   ├── debian13/config.yaml
│   ├── ubuntu2204/config.yaml
│   ├── ubuntu2404/config.yaml
│   └── rocky10/config.yaml
├── scripts/
│   ├── build-with-cloudinit.sh     # Cloud-Init 构建脚本 (推荐)
│   ├── generate-cloud-init.sh      # 仅生成 cloud-init ISO
│   └── build-image.sh              # virt-customize 构建脚本
├── output/                         # 构建输出
└── README.md
```

## 输出文件

### Cloud-Init 方式输出

```
output/
├── debian12-base-amd64.qcow2           # 虚拟机镜像
├── debian12-base-amd64.qcow2.sha256    # 镜像校验和
├── debian12-base-cloudinit.iso         # cloud-init 配置 ISO
└── debian12-base-cloudinit.iso.sha256  # ISO 校验和
```

### virt-customize 方式输出

```
output/
├── debian12-base-amd64.qcow2
├── debian12-base-amd64.qcow2.sha256
├── debian12-base-arm64.qcow2
└── debian12-base-arm64.qcow2.sha256
```

## 导入 PVE

### Cloud-Init 方式

```bash
# 上传文件到 PVE
scp output/debian12-base-amd64.qcow2 root@pve:/var/lib/vz/template/qcow2/
scp output/debian12-base-cloudinit.iso root@pve:/var/lib/vz/template/iso/

# 创建 VM
qm create 100 --name my-vm --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0

# 导入磁盘
qm importdisk 100 /var/lib/vz/template/qcow2/debian12-base-amd64.qcow2 local-lvm

# 配置磁盘和 CD-ROM
qm set 100 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-100-disk-0
qm set 100 --ide2 local:iso/debian12-base-cloudinit.iso,media=cdrom

# 启动 VM
qm start 100
```

### virt-customize 方式

```bash
# 上传到 PVE
scp output/debian12-base-amd64.qcow2 root@pve:/var/lib/vz/template/qcow2/

# 导入镜像 (方法1: 创建模板)
qm create 9000 --name debian12-template --memory 2048 --cores 2
qm importdisk 9000 debian12-base-amd64.qcow2 local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm template 9000

# 导入镜像 (方法2: 直接创建 VM)
qm create 100 --name my-vm --memory 2048 --cores 2
qm importdisk 100 debian12-base-amd64.qcow2 local-lvm
qm set 100 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-100-disk-0
```

## 配置说明

```yaml
name: debian12-base
description: 描述
version: "1.0.0"

source:
  amd64: https://.../amd64.qcow2    # amd64 镜像 URL
  arm64: https://.../arm64.qcow2    # arm64 镜像 URL

disk:
  size: 10G

settings:
  timezone: Asia/Shanghai
  hostname: debian12

# Debian/Ubuntu
apt:
  mirror: https://mirrors.tuna.tsinghua.edu.cn/debian

# Rocky/CentOS
dnf:
  mirror: https://mirrors.tuna.tsinghua.edu.cn/rocky

packages:
  - vim
  - curl

files:
  - path: /etc/motd
    content: |
      Welcome!
    permissions: "0644"

commands:
  - systemctl enable qemu-guest-agent
```

## License

MIT
