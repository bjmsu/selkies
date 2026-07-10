#!/bin/bash
# Install selkies as a boot service on port 80. Run with sudo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 安装服务单元"
cp "$HERE/selkies.service" /etc/systemd/system/selkies.service
systemctl daemon-reload

echo "==> 开启用户 linger(开机即建 /run/user/1000 + pipewire,无需登录)"
loginctl enable-linger kubuntu

echo "==> 启用并启动"
systemctl enable --now selkies

sleep 3
systemctl status selkies --no-pager | head -8
echo
ss -tln | grep -E ':80 ' && echo "==> 80 端口已监听 ✓" || echo "!! 80 未监听,查日志: journalctl -u selkies -e"
