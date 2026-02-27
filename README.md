# VM Base Image Builder (PVE)

用于构建可复用的 `qcow2` 基础镜像，并在 Proxmox VE 中快速创建模板。

## 方案说明

本仓库采用以下模型：

1. GitHub Actions 负责构建和发布 `qcow2` 镜像（不写死账号/密码）。
2. PVE 侧仅导入 `qcow2` + 挂载 cloud-init 盘 + 转模板（模板阶段不启动）。
3. 克隆实例后，在 PVE GUI 的 Cloud-Init 页面配置 `ciuser/sshkeys/ipconfig0`。

这样可以避免 `cicustom user=...` 与 GUI 认证参数互相覆盖。

## 支持镜像

| OS | 标识 | amd64 | arm64 |
|:---|:---|:---:|:---:|
| Debian 12 | `debian12` | ✅ | ✅ |
| Debian 13 | `debian13` | ✅ | ✅ |
| Ubuntu 22.04 | `ubuntu2204` | ✅ | ✅ |
| Ubuntu 24.04 | `ubuntu2404` | ✅ | ✅ |
| Rocky Linux 10 | `rocky10` | ✅ | ✅ |

## GitHub Actions 构建

工作流文件：`.github/workflows/build-qcow2.yml`

### 触发方式

- `push`（配置或构建脚本变化时）
- `pull_request`
- 手动触发 `workflow_dispatch`

### 手动参数

- `image`: 镜像名或 `all`
- `arch`: `amd64` / `arm64`
- `version`: 版本号（如 `v1.0.0`，非空时会发 Release）

### 产物

- `<name>-<arch>.qcow2`
- `<name>-<arch>.qcow2.sha256`

## 在 PVE 创建模板

```bash
# 在 PVE 主机执行
./scripts/pve-create-template.sh debian13 amd64 9011 \
  --storage hdd-pool \
  --release latest
```

常见参数：

- `--release <tag>`: 选择 Release 版本（默认 `latest`）
- `--repo <owner/repo>`: 默认 `gclm/vm-images`
- `--image-url <url>`: 直接指定 qcow2 下载链接
- `--sshkey-file <path>`: 可选，给模板预置 key（通常建议在克隆实例阶段再设置）
- `--cicustom user=...`: 可选，不建议与 GUI `ciuser/sshkeys` 混用

## 推荐实例化流程（PVE GUI）

1. 从模板克隆 VM。
2. 打开克隆机的 `Cloud-Init` 页面。
3. 配置：
   - `User` (`ciuser`)
   - `SSH public key` (`sshkeys`)
   - `IP config` (`ipconfig0`)
4. 启动克隆机，cloud-init 在首次启动时应用配置。

## 配置文件

镜像基础定制位于 `images/<os>/config.yaml`，包含：

- 源镜像地址
- 磁盘大小
- 时区/主机名/locale
- 需要预装的软件包
- 写入的静态文件
- 首次构建时执行的命令

不包含实例级认证信息（账号/密码/SSH key）。

## 目录结构

```text
iso/
├── .github/workflows/build-qcow2.yml
├── images/
│   ├── debian12/config.yaml
│   ├── debian13/config.yaml
│   ├── ubuntu2204/config.yaml
│   ├── ubuntu2404/config.yaml
│   └── rocky10/config.yaml
├── scripts/
│   ├── build-image.sh
│   └── pve-create-template.sh
└── README.md
```
