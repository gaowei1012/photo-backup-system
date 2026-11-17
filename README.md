# Photo Backup System — 发布包与部署

本仓库存放**已编译**的 Linux 服务端发布包（含管理后台静态资源），用于生产环境一键安装或手动部署。不依赖 Docker。

## 发布包内容

| 文件 | 说明 |
|------|------|
| `photobackup-linux-amd64.tar.gz` | x86_64 |
| `photobackup-linux-arm64.tar.gz` | ARM64（树莓派 4/5 64 位等） |
| `photobackup-linux-armv7.tar.gz` | ARMv7（部分 32 位板卡） |
| `install.sh` / `install-pi.sh` | 一键安装脚本 |
| `SHA256SUMS` | 校验和 |

解压后目录结构：

```text
photobackup-linux-<arch>/
├── bin/photobackup          # 服务端二进制
├── admin/                   # Web 管理后台
├── migrations/              # 数据库迁移
├── deploy/photobackup.service
├── .env.example
├── VERSION
└── ARCH
```

默认安装目录：`/opt/photobackup`  
默认端口：`13400`  
systemd 服务名：`photobackup`

---

## 方式一：一键安装（推荐）

在目标 Linux 机器上执行（需 root / sudo）：

```bash
# 通用 Linux（脚本与发布包均来自本仓库）
curl -fsSL -o install.sh \
  https://raw.githubusercontent.com/gaowei1012/photo-backup-system/main/install.sh
sudo bash install.sh
```

树莓派：

```bash
curl -fsSL -o install-pi.sh \
  https://raw.githubusercontent.com/gaowei1012/photo-backup-system/main/install-pi.sh
sudo bash install-pi.sh
```

指定某个包地址：

```bash
TARBALL_URL=https://github.com/gaowei1012/photo-backup-system/releases/download/v1.0.0/photobackup-linux-arm64.tar.gz \
  sudo bash install.sh
```

若 GitHub raw 仍不稳定，可从本机拷贝脚本到服务器后再执行（见下方「离线安装」）。

> 注意：源码在私有 GitLab，**不要**再使用 `raw.githubusercontent.com/ouistudio/...`（会 404）。

安装脚本会：检测架构 → 安装依赖（MySQL/MariaDB、ffmpeg 等）→ 解压到 `/opt/photobackup` → 生成 `.env` → 注册并启动 systemd。

### 离线安装（推荐，国内网络）

在能访问本仓库的电脑上，把脚本和对应架构包拷到服务器：

```bash
# 本机（有 dist 目录时）
scp install.sh photobackup-linux-amd64.tar.gz user@服务器:/tmp/

# 服务器上
cd /tmp
TARBALL_URL=file:///tmp/photobackup-linux-amd64.tar.gz sudo bash install.sh
```

树莓派把包名换成 `photobackup-linux-arm64.tar.gz`（或 armv7）。

常用环境变量：

| 变量 | 默认 | 说明 |
|------|------|------|
| `INSTALL_DIR` | `/opt/photobackup` | 安装目录 |
| `APP_PORT` | `13400` | 监听端口 |
| `RELEASE_BASE_URL` | GitHub latest/download | 包下载前缀 |
| `TARBALL_URL` | 空 | 直接指定 `.tar.gz`（优先级最高） |
| `WITH_MYSQL` | `1` | `0` = 使用已有远程 MySQL |
| `SKIP_DEPS` | `0` | `1` = 不装系统依赖 |

---

## 方式二：手动解压部署

### 1. 下载并校验

```bash
VER=v1.0.0   # 或 latest 对应的 tag
BASE=https://github.com/gaowei1012/photo-backup-system/releases/download/${VER}

# 按机器架构二选一
curl -fLO ${BASE}/photobackup-linux-amd64.tar.gz
# curl -fLO ${BASE}/photobackup-linux-arm64.tar.gz
# curl -fLO ${BASE}/photobackup-linux-armv7.tar.gz
curl -fLO ${BASE}/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

### 2. 解压到安装目录

```bash
sudo mkdir -p /opt/photobackup
sudo tar -xzf photobackup-linux-amd64.tar.gz -C /tmp
sudo cp -a /tmp/photobackup-linux-amd64/. /opt/photobackup/
sudo mkdir -p /opt/photobackup/data/{uploads,thumbnails,chunks}
sudo chmod +x /opt/photobackup/bin/photobackup
```

### 3. 配置环境变量

```bash
sudo cp /opt/photobackup/.env.example /opt/photobackup/.env
sudo chmod 600 /opt/photobackup/.env
sudo nano /opt/photobackup/.env
```

至少修改：

- `JWT_SECRET`（≥ 32 字符随机串）
- `DB_PASSWORD` / `DB_HOST` 等数据库项
- `ADMIN_USERNAME` / `ADMIN_PASSWORD`

示例（本机 MySQL）：

```bash
APP_PORT=13400
SERVER_MODE=production
LOG_LEVEL=info
JWT_SECRET=请换成足够长的随机字符串
JWT_EXPIRE_HOURS=168
DB_DRIVER=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=photobackup
DB_PASSWORD=请换成强密码
DB_NAME=photobackup
DB_MAX_CONNS=20
STORAGE_PATH=/opt/photobackup/data/uploads
THUMBNAIL_PATH=/opt/photobackup/data/thumbnails
CHUNK_PATH=/opt/photobackup/data/chunks
MIGRATIONS_DIR=/opt/photobackup/migrations
ADMIN_WEB_DIR=/opt/photobackup/admin
ADMIN_USERNAME=admin
ADMIN_PASSWORD=请修改
RATE_LIMIT=300
```

准备数据库（示例）：

```bash
sudo mysql -e "CREATE DATABASE IF NOT EXISTS photobackup CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'photobackup'@'localhost' IDENTIFIED BY '你的密码';
GRANT ALL ON photobackup.* TO 'photobackup'@'localhost';
FLUSH PRIVILEGES;"
```

迁移在进程启动时自动执行，一般无需手动跑。

### 4. 系统用户与权限

```bash
sudo useradd --system --home-dir /opt/photobackup --shell /usr/sbin/nologin photobackup 2>/dev/null || true
sudo chown -R photobackup:photobackup /opt/photobackup
```

### 5. 注册 systemd 并启动

```bash
sudo cp /opt/photobackup/deploy/photobackup.service /etc/systemd/system/photobackup.service
# 若安装目录不是 /opt/photobackup，请编辑 unit 中的路径
sudo systemctl daemon-reload
sudo systemctl enable --now photobackup
```

### 6. 验证

```bash
curl -fsS http://127.0.0.1:13400/health
sudo systemctl status photobackup
```

- API / 健康检查：`http://<主机>:13400/health`
- 管理后台：`http://<主机>:13400/`（Basic Auth，账号见 `.env`）

手机客户端局域网填写：`http://<主机局域网IP>:13400`；公网请前置 HTTPS 反向代理。

---

## 日常运维

```bash
sudo systemctl status photobackup      # 状态
sudo systemctl restart photobackup     # 重启
sudo systemctl stop photobackup        # 停止
sudo journalctl -u photobackup -f      # 日志
```

修改 `/opt/photobackup/.env` 后需 `sudo systemctl restart photobackup`。

数据目录（默认）：

| 路径 | 用途 |
|------|------|
| `data/uploads` | 用户备份原文件 |
| `data/thumbnails` | 缩略图 |
| `data/chunks` | 分片上传临时文件 |

备份建议：定期备份 MySQL 库 `photobackup` 与 `data/uploads`（及 `.env`）。

---

## 升级

1. 下载新版本对应架构的 `.tar.gz`
2. 停止服务：`sudo systemctl stop photobackup`
3. 覆盖 `bin/`、`admin/`、`migrations/`（**保留** `.env` 与 `data/`）
4. 启动：`sudo systemctl start photobackup`
5. 看日志与 `/health`

示例：

```bash
VER=v1.0.1
ARCH=amd64   # 或 arm64 / armv7
curl -fLO https://github.com/gaowei1012/photo-backup-system/releases/download/${VER}/photobackup-linux-${ARCH}.tar.gz
sudo systemctl stop photobackup
sudo tar -xzf photobackup-linux-${ARCH}.tar.gz -C /tmp
sudo cp -a /tmp/photobackup-linux-${ARCH}/bin /tmp/photobackup-linux-${ARCH}/admin /tmp/photobackup-linux-${ARCH}/migrations /opt/photobackup/
sudo chown -R photobackup:photobackup /opt/photobackup
sudo systemctl start photobackup
curl -fsS http://127.0.0.1:13400/health
```

---

## 依赖与端口

| 依赖 | 说明 |
|------|------|
| Linux + systemd | 推荐发行版：Debian / Ubuntu / Raspberry Pi OS |
| MySQL 8 或 MariaDB | 本机或远程均可 |
| ffmpeg | 缩略图 / 媒体处理（一键安装会尝试装上） |

| 端口 | 说明 |
|------|------|
| `13400` | HTTP API + 管理后台（可用 `APP_PORT` 修改） |
| `3306` | MySQL（仅本机库时） |

生产环境务必使用 HTTPS（Nginx / Caddy 等反向代理），并修改默认管理员密码与 `JWT_SECRET`。

---

## 前台临时运行（不装 systemd）

适合调试：

```bash
cd /opt/photobackup
set -a && source .env && set +a
./bin/photobackup
```

---

## 发布说明（维护者）

在源码仓库执行：

```bash
VERSION=v1.0.0 ./scripts/build-release.sh
# 产物写入本 dist 目录的 *.tar.gz 与 SHA256SUMS
```

将上述文件提交到本发布仓库，打 `v*` tag；`.github/workflows/release.yml` 会把包挂到 GitHub Release，安装端即可通过 `RELEASE_BASE_URL=.../releases/latest/download` 拉取。
