# VM 基础镜像构建工具

为 PVE (Proxmox VE) 快速部署预配置的虚拟机模板。

## 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions CI                         │
│  ┌─────────────┐                                            │
│  │ config.yaml │ ──→ 生成 ──→ cloud-init ISO                │
│  └─────────────┘                                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ 发布到 GitHub Release
┌─────────────────────────────────────────────────────────────┐
│                      PVE 服务器                              │
│                                                              │
│  pve-create-template.sh debian12 amd64 9000                 │
│       │                                                      │
│       ├── 下载官方镜像 (debian-12-genericcloud-amd64.qcow2) │
│       ├── 下载 cloud-init ISO (从 GitHub Release)           │
│       ├── 创建 VM                                           │
│       └── 转换为模板                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 支持的镜像

| 操作系统 | 名称 | amd64 | arm64 |
|:---|:---|:---:|:---:|
| Debian 12 (Bookworm) | `debian12` | ✅ | ✅ |
| Debian 13 (Trixie) | `debian13` | ✅ | ✅ |
| Ubuntu 22.04 (Jammy) | `ubuntu2204` | ✅ | ✅ |
| Ubuntu 24.04 (Noble) | `ubuntu2404` | ✅ | ✅ |
| Rocky Linux 10 | `rocky10` | ✅ | ✅ |

## 快速开始

### 1. 配置 GitHub Secrets

在仓库设置中配置：

| Secret | 说明 |
|:---|:---|
| `SSH_PUBLIC_KEY` | SSH 公钥 |
| `ROOT_PASSWORD` | root 密码 |

### 2. 触发 CI 构建

- Push 到 main 分支自动构建
- 手动触发：Actions → Build Cloud-Init ISO → Run workflow

### 3. 在 PVE 上创建模板

```bash
# 下载脚本
wget https://raw.githubusercontent.com/gclm/vm-images/main/scripts/pve-create-template.sh
chmod +x pve-create-template.sh

# 创建模板
./pve-create-template.sh debian12 amd64 9000

# 创建更多模板
./pve-create-template.sh ubuntu2404 amd64 9001
./pve-create-template.sh rocky10 amd64 9002
```

## PVE 脚本详细用法

### 基本用法

```bash
./pve-create-template.sh <os> <arch> <vmid> [options]
```

### 参数

| 参数 | 说明 | 示例 |
|:---|:---|:---|
| `os` | 操作系统名称 | `debian12`, `ubuntu2404` |
| `arch` | 架构 | `amd64`, `arm64` |
| `vmid` | VM ID (数字) | `9000` |

### 选项

| 选项 | 说明 | 默认值 |
|:---|:---|:---|
| `--storage` | 存储名称 | `local-lvm` |
| `--bridge` | 网桥名称 | `vmbr0` |
| `--memory` | 内存 (MB) | `2048` |
| `--cores` | CPU 核心数 | `2` |
| `--disk-size` | 磁盘大小 | `10G` |
| `--release` | GitHub Release 版本 | `latest` |
| `--no-template` | 不转换为模板 | - |
| `--skip-download` | 使用已下载的文件 | - |

### 示例

```bash
# 基本用法
./pve-create-template.sh debian12 amd64 9000

# 自定义配置
./pve-create-template.sh ubuntu2404 amd64 9001 \
    --storage local-zfs \
    --memory 4096 \
    --cores 4 \
    --disk-size 20G

# 使用指定版本
./pve-create-template.sh debian12 amd64 9000 --release v1.0.0

# 创建 VM 但不转换为模板（用于调试）
./pve-create-template.sh debian12 amd64 9002 --no-template
```

## 配置说明

编辑 `images/<os>/config.yaml` 自定义镜像配置：

```yaml
name: debian12-base
version: "1.0.0"

settings:
  timezone: Asia/Shanghai
  hostname: debian12

packages:
  - vim
  - curl
  - wget
  - git
  - htop

users:
  - name: debian
    password_env: ROOT_PASSWORD
    ssh_key_env: SSH_PUBLIC_KEY

files:
  - path: /etc/motd
    content: |
      Welcome to Debian 12!
    permissions: "0644"

commands:
  - systemctl enable qemu-guest-agent
```

## 目录结构

```
iso/
├── .github/workflows/
│   └── build-cloudinit.yml    # CI 工作流
├── images/
│   ├── debian12/config.yaml
│   ├── debian13/config.yaml
│   ├── ubuntu2204/config.yaml
│   ├── ubuntu2404/config.yaml
│   └── rocky10/config.yaml
├── scripts/
│   ├── generate-cloud-init.sh # 生成 cloud-init ISO
│   └── pve-create-template.sh # PVE 一键脚本
└── README.md
```

## 手动发布 Release

1. 进入 Actions → Build Cloud-Init ISO → Run workflow
2. 填写版本号（如 `v1.0.0`）
3. CI 会自动创建 tag 和 release

## 常见问题

### Q: cloud-init 配置什么时候应用？

A: VM 首次启动时。cloud-init 通过 `instance-id` 判断是否首次启动，重启不会重复执行。

### Q: 如何修改已有模板的配置？

A: 需要重新生成 cloud-init ISO（在 CI 中修改 config.yaml），然后在 PVE 上重新创建模板。

### Q: 支持哪些 PVE 版本？

A: PVE 7.x 和 8.x 均支持。

## License

MIT
