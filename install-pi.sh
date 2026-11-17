#!/usr/bin/env bash
# 树莓派专用一键安装（原生二进制 + systemd，不安装 Docker）
# 适用：Raspberry Pi OS 32/64 位，Pi 3 / 4 / 5
#
# 用法：
#   curl -fsSL -o install-pi.sh https://raw.githubusercontent.com/gaowei1012/photo-backup-system/main/install-pi.sh
#   sudo bash install-pi.sh
#
# 可选环境变量同 install.sh，例如：
#   INSTALL_DIR=/opt/photobackup APP_PORT=13400
#   RELEASE_BASE_URL=https://your.cdn/releases
#   TARBALL_URL=https://your.cdn/photobackup-linux-arm64.tar.gz
set -euo pipefail

export INSTALL_DIR="${INSTALL_DIR:-/opt/photobackup}"
export APP_PORT="${APP_PORT:-13400}"
export RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/gaowei1012/photo-backup-system/releases/latest/download}"
export WITH_MYSQL="${WITH_MYSQL:-${WITH_POSTGRES:-1}}"

echo "Photo Backup — 树莓派原生安装（无 Docker）"
echo "建议: Pi 4/5 + 外接磁盘存放相册；系统盘可用 microSD"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/gaowei1012/photo-backup-system/main}"

if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/install.sh" ]; then
  exec bash "${SCRIPT_DIR}/install.sh" "$@"
fi

if command -v curl >/dev/null 2>&1; then
  exec bash -c "$(curl -fsSL "${RAW_BASE_URL}/install.sh")"
elif command -v wget >/dev/null 2>&1; then
  exec bash -c "$(wget -qO- "${RAW_BASE_URL}/install.sh")"
else
  echo "需要 curl 或 wget" >&2
  exit 1
fi
