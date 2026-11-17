#!/usr/bin/env bash
# Photo Backup System 一键安装（原生二进制 + systemd，不依赖 Docker）
# 支持：Linux x86_64 / arm64 / armv7（含树莓派）
#
# 用法：
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/gaowei1012/photo-backup-system/main/install.sh
#   sudo bash install.sh
#
# 环境变量：
#   INSTALL_DIR=/opt/photobackup
#   APP_PORT=13400
#   RELEASE_BASE_URL=https://github.com/gaowei1012/photo-backup-system/releases/latest/download
#   VERSION=latest          # 或 v1.0.0（配合 RELEASE_BASE_URL 指向具体 tag）
#   TARBALL_URL=            # 直接指定包地址，优先级最高
#   SKIP_DEPS=0             # 1=不装系统依赖（需已有 mysql/mariadb/ffmpeg）
#   WITH_MYSQL=1            # 0=跳过本机 MySQL/MariaDB（使用已有远程库）
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/photobackup}"
APP_PORT="${APP_PORT:-13400}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/gaowei1012/photo-backup-system/releases/latest/download}"
VERSION="${VERSION:-latest}"
TARBALL_URL="${TARBALL_URL:-}"
SKIP_DEPS="${SKIP_DEPS:-0}"
WITH_MYSQL="${WITH_MYSQL:-${WITH_POSTGRES:-1}}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
SERVICE_NAME="photobackup"
SERVICE_USER="photobackup"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
info()  { echo "${CYAN}==>${RESET} $*"; }
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
die()   { echo "${RED}错误:${RESET} $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      die "请使用 root 运行，或安装 sudo"
    fi
  else
    SUDO=""
  fi
}

run() {
  if [ -n "${SUDO}" ]; then
    # shellcheck disable=SC2086
    $SUDO "$@"
  else
    "$@"
  fi
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH_SUFFIX=amd64 ;;
    aarch64|arm64) ARCH_SUFFIX=arm64 ;;
    armv7l|armhf) ARCH_SUFFIX=armv7 ;;
    armv6l) die "不支持 armv6，请使用 32 位 armv7 或 64 位系统（Pi 3+）" ;;
    *) die "不支持的架构: $m" ;;
  esac
  ok "架构: $(uname -m) → linux-${ARCH_SUFFIX}"
}

detect_raspberry_pi() {
  IS_PI=0
  if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
    IS_PI=1
  elif grep -qi "raspberry" /proc/cpuinfo 2>/dev/null; then
    IS_PI=1
  fi
  if [ "$IS_PI" = "1" ]; then
    local model
    model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo 'Raspberry Pi')"
    ok "检测到树莓派: ${model}"
  fi
}

mem_mb() {
  awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

ensure_swap_on_pi() {
  [ "$IS_PI" = "1" ] || return 0
  local mb
  mb="$(mem_mb)"
  if [ "$mb" -gt 0 ] && [ "$mb" -lt 1900 ]; then
    if [ ! -f /swapfile ] && ! swapon --show 2>/dev/null | grep -q .; then
      warn "内存约 ${mb}MB，创建 1G swap"
      run fallocate -l 1G /swapfile 2>/dev/null || run dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
      run chmod 600 /swapfile
      run mkswap /swapfile
      run swapon /swapfile
      if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' | run tee -a /etc/fstab >/dev/null
      fi
      ok "已启用 swap"
    fi
  fi
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    run apt-get update -qq
    run DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null 2>&1; then
    run dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    run yum install -y "$@"
  else
    die "未找到 apt/dnf/yum，请手动安装: $*"
  fi
}

install_deps() {
  [ "$SKIP_DEPS" = "1" ] && { ok "SKIP_DEPS=1，跳过系统依赖"; return 0; }

  info "安装系统依赖（curl/ffmpeg/heif，可选 MySQL/MariaDB）..."
  local pkgs=(ca-certificates curl wget tar)
  # 缩略图：JPEG 纯 Go；HEIC/视频需要这些
  pkgs+=(ffmpeg)

  if [ "$WITH_MYSQL" = "1" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      pkgs+=(default-mysql-server default-mysql-client)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      pkgs+=(mariadb-server mariadb)
    fi
  fi

  pkg_install "${pkgs[@]}" || {
    warn "部分软件包安装失败，尝试精简依赖重试"
    pkg_install ca-certificates curl wget tar ffmpeg default-mysql-server || \
      pkg_install ca-certificates curl wget tar ffmpeg mariadb-server || die "依赖安装失败"
  }

  # libheif-examples 在部分源可能无，忽略失败
  if command -v apt-get >/dev/null 2>&1; then
    run DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libheif-examples 2>/dev/null || \
      warn "未安装 libheif-examples（HEIC 缩略图可能不可用，JPEG/视频仍可用）"
  fi

  ok "系统依赖就绪"
}

mysql_exec() {
  # 优先用 root socket（Debian/Ubuntu/MariaDB 默认）
  if mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql -uroot "$@"
  elif [ -n "${SUDO}" ] && ${SUDO} mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    ${SUDO} mysql -uroot "$@"
  else
    die "无法以 root 连接 MySQL/MariaDB，请手动创建库后设置 WITH_MYSQL=0"
  fi
}

setup_mysql() {
  [ "$WITH_MYSQL" = "1" ] || { ok "使用外部数据库（WITH_MYSQL=0）"; return 0; }

  info "配置本机 MySQL/MariaDB..."
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl enable --now mysql 2>/dev/null \
      || run systemctl enable --now mariadb 2>/dev/null \
      || run systemctl enable --now mysqld 2>/dev/null \
      || true
  fi

  command -v mysql >/dev/null 2>&1 || die "mysql 客户端不可用，请检查 MySQL/MariaDB 是否安装成功"

  local pass="$1"
  local pass_sql
  pass_sql="$(printf '%s' "$pass" | sed "s/'/\\\\'/g")"

  mysql_exec -e "CREATE DATABASE IF NOT EXISTS photobackup CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_exec -e "CREATE USER IF NOT EXISTS '${SERVICE_USER}'@'localhost' IDENTIFIED BY '${pass_sql}';" 2>/dev/null \
    || mysql_exec -e "CREATE USER '${SERVICE_USER}'@'localhost' IDENTIFIED BY '${pass_sql}';" 2>/dev/null \
    || mysql_exec -e "ALTER USER '${SERVICE_USER}'@'localhost' IDENTIFIED BY '${pass_sql}';"
  mysql_exec -e "ALTER USER '${SERVICE_USER}'@'localhost' IDENTIFIED BY '${pass_sql}';" 2>/dev/null || true
  mysql_exec -e "GRANT ALL PRIVILEGES ON photobackup.* TO '${SERVICE_USER}'@'localhost'; FLUSH PRIVILEGES;"

  # 树莓派降低内存占用
  if [ "$IS_PI" = "1" ]; then
    local mb buffer=64M
    mb="$(mem_mb)"
    if [ "$mb" -ge 1900 ]; then
      buffer=128M
    fi
    info "调优 MySQL/MariaDB（innodb_buffer_pool_size=${buffer}）"
    local conf="/etc/mysql/conf.d/photobackup-pi.cnf"
    if [ ! -d "$(dirname "$conf")" ]; then
      conf="/etc/my.cnf.d/photobackup-pi.cnf"
      run mkdir -p "$(dirname "$conf")" 2>/dev/null || true
    fi
    if [ -d "$(dirname "$conf")" ]; then
      cat <<EOF | run tee "$conf" >/dev/null
[mysqld]
innodb_buffer_pool_size=${buffer}
max_connections=50
EOF
      run systemctl restart mysql 2>/dev/null || run systemctl restart mariadb 2>/dev/null || true
    fi
  fi
  ok "MySQL/MariaDB 已就绪"
}

rand_secret() {
  local n="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$((n * 2))" | tr -d '\n=/' | cut -c1-"$n"
  else
    head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$n"
  fi
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  else
    wget -O "$dest" "$url"
  fi
}

resolve_tarball_url() {
  if [ -n "$TARBALL_URL" ]; then
    echo "$TARBALL_URL"
    return
  fi
  echo "${RELEASE_BASE_URL}/photobackup-linux-${ARCH_SUFFIX}.tar.gz"
}

install_binary() {
  local url tmp work
  url="$(resolve_tarball_url)"
  info "下载: $url"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if ! download "$url" "$tmp/pkg.tar.gz"; then
    die "下载失败。请先执行 ./scripts/build-release.sh 并上传发布包，或设置 TARBALL_URL / RELEASE_BASE_URL
示例（本机已有包）:
  TARBALL_URL=file:///path/to/photobackup-linux-${ARCH_SUFFIX}.tar.gz bash install.sh
  或
  BUILD_LOCAL=1（见下方从源码安装）"
  fi

  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp"
  work="$(find "$tmp" -maxdepth 1 -type d -name 'photobackup-linux-*' | head -1)"
  [ -n "$work" ] || die "压缩包格式不正确"

  run mkdir -p "$INSTALL_DIR"
  run cp -a "$work/bin" "$work/migrations" "$work/admin" "$INSTALL_DIR/"
  if [ -d "$work/deploy" ]; then
    run mkdir -p "$INSTALL_DIR/deploy"
    run cp -a "$work/deploy/." "$INSTALL_DIR/deploy/"
  fi
  [ -f "$work/VERSION" ] && run cp "$work/VERSION" "$INSTALL_DIR/VERSION"
  run mkdir -p "$INSTALL_DIR/data/uploads" "$INSTALL_DIR/data/thumbnails" "$INSTALL_DIR/data/chunks"
  run chmod +x "$INSTALL_DIR/bin/photobackup"
  ok "文件已安装到 ${INSTALL_DIR}"
}

install_from_local_build() {
  info "本地编译安装（BUILD_LOCAL=1）..."
  local root script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$script_dir" ] && [ -f "${script_dir}/build-release.sh" ]; then
    root="$(cd "${script_dir}/.." && pwd)"
  else
    die "BUILD_LOCAL=1 需要在仓库内执行，或先 build-release 后设置 TARBALL_URL"
  fi
  command -v go >/dev/null 2>&1 || die "本地编译需要安装 Go"
  command -v npm >/dev/null 2>&1 || die "本地编译需要安装 Node.js / npm"
  ONLY_ARCH="$ARCH_SUFFIX" OUT="${root}/dist" bash "${root}/scripts/build-release.sh"

  local tmp work
  tmp="$(mktemp -d)"
  tar -xzf "${root}/dist/photobackup-linux-${ARCH_SUFFIX}.tar.gz" -C "$tmp"
  work="$(find "$tmp" -maxdepth 1 -type d -name 'photobackup-linux-*' | head -1)"
  [ -n "$work" ] || die "本地构建产物缺失"
  run mkdir -p "$INSTALL_DIR"
  run cp -a "$work/bin" "$work/migrations" "$work/admin" "$INSTALL_DIR/"
  [ -d "$work/deploy" ] && run mkdir -p "$INSTALL_DIR/deploy" && run cp -a "$work/deploy/." "$INSTALL_DIR/deploy/"
  [ -f "$work/VERSION" ] && run cp "$work/VERSION" "$INSTALL_DIR/VERSION"
  run mkdir -p "$INSTALL_DIR/data/uploads" "$INSTALL_DIR/data/thumbnails" "$INSTALL_DIR/data/chunks"
  run chmod +x "$INSTALL_DIR/bin/photobackup"
  rm -rf "$tmp"
  ok "本地构建已安装到 ${INSTALL_DIR}"
}

ensure_user() {
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    run useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
      || run useradd --system --home-dir "$INSTALL_DIR" --shell /sbin/nologin "$SERVICE_USER"
    ok "已创建系统用户 ${SERVICE_USER}"
  fi
  run chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
}

write_env() {
  local envf="${INSTALL_DIR}/.env"
  local pass admin_pass jwt db_max=20
  if [ -f "$envf" ]; then
    ok ".env 已存在，保留"
    # shellcheck disable=SC1090
    DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "$envf" | cut -d= -f2-)"
    return 0
  fi
  jwt="$(rand_secret 48)"
  pass="$(rand_secret 24)"
  admin_pass="$(rand_secret 16)"
  DB_PASSWORD="$pass"
  if [ "$IS_PI" = "1" ]; then
    local mb
    mb="$(mem_mb)"
    if [ "$mb" -lt 1900 ]; then
      db_max=10
    else
      db_max=15
    fi
  fi
  cat <<EOF | run tee "$envf" >/dev/null
APP_PORT=${APP_PORT}
SERVER_MODE=production
LOG_LEVEL=info
JWT_SECRET=${jwt}
JWT_EXPIRE_HOURS=168
DB_DRIVER=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=${SERVICE_USER}
DB_PASSWORD=${pass}
DB_NAME=photobackup
DB_MAX_CONNS=${db_max}
STORAGE_PATH=${INSTALL_DIR}/data/uploads
THUMBNAIL_PATH=${INSTALL_DIR}/data/thumbnails
CHUNK_PATH=${INSTALL_DIR}/data/chunks
MIGRATIONS_DIR=${INSTALL_DIR}/migrations
ADMIN_WEB_DIR=${INSTALL_DIR}/admin
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${admin_pass}
RATE_LIMIT=300
EOF
  run chmod 600 "$envf"
  run chown "${SERVICE_USER}:${SERVICE_USER}" "$envf"
  ok "已生成 .env"
  echo "    管理后台: ${ADMIN_USERNAME} / ${admin_pass}"
}

install_systemd() {
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  local src="${INSTALL_DIR}/deploy/photobackup.service"
  if [ -f "$src" ]; then
    run cp "$src" "$unit"
  else
    cat <<EOF | run tee "$unit" >/dev/null
[Unit]
Description=Photo Backup System
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/bin/photobackup
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  fi
  # 按实际安装路径修正
  run sed -i "s|/opt/photobackup|${INSTALL_DIR}|g" "$unit"
  if [ "$WITH_MYSQL" != "1" ]; then
    run sed -i '/mysql.service/d; /mariadb.service/d' "$unit"
  fi
  run systemctl daemon-reload
  run systemctl enable --now "${SERVICE_NAME}.service"
  ok "systemd 服务已启动: ${SERVICE_NAME}"
}

wait_health() {
  info "等待服务就绪..."
  local i
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 \
      || wget -qO- "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
      ok "后端已就绪: http://127.0.0.1:${APP_PORT}"
      return 0
    fi
    sleep 1
  done
  warn "健康检查超时，日志: journalctl -u ${SERVICE_NAME} -f"
  run systemctl --no-pager --full status "${SERVICE_NAME}" || true
  return 1
}

print_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$ip" ] && ip="<本机IP>"
  echo
  echo "${GREEN}======== 安装完成（无 Docker） ========${RESET}"
  echo "目录:     ${INSTALL_DIR}"
  echo "本机:     http://127.0.0.1:${APP_PORT}"
  echo "局域网:   http://${ip}:${APP_PORT}"
  echo "管理后台: http://${ip}:${APP_PORT}/  （账号见 ${INSTALL_DIR}/.env）"
  echo
  echo "常用命令:"
  echo "  sudo systemctl status ${SERVICE_NAME}"
  echo "  sudo journalctl -u ${SERVICE_NAME} -f"
  echo "  sudo systemctl restart ${SERVICE_NAME}"
  if [ "$IS_PI" = "1" ]; then
    echo
    echo "树莓派建议: 数据盘用外接 SSD，修改 .env 中 STORAGE_PATH 等后 restart"
  fi
}

main() {
  echo "${CYAN}Photo Backup System 一键安装（原生二进制）${RESET}"
  uname -s | grep -qi linux || die "仅支持 Linux"
  need_root
  detect_arch
  detect_raspberry_pi
  ensure_swap_on_pi
  install_deps

  if [ "${BUILD_LOCAL:-0}" = "1" ]; then
    install_from_local_build
  else
    install_binary
  fi

  ensure_user
  write_env
  setup_mysql "${DB_PASSWORD}"
  # 再次确保权限（数据库配置后）
  run chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
  install_systemd
  wait_health || true
  print_summary
}

main "$@"
