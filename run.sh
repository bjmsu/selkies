#!/usr/bin/env bash
#
# 启动新版 selkies（pixelflux 架构），自动检查/生成自签名证书，
# 设置好 xrdp DISPLAY 环境变量后启动。
#
# 用法：
#   ./run.sh                启动
#   PORT=8082 ./run.sh       换端口
#
set -euo pipefail

VENV="$HOME/selkies-new-venv"
CERT_DIR="$VENV/certs"
CERT_FILE="$CERT_DIR/selkies.crt"
KEY_FILE="$CERT_DIR/selkies.key"

: "${PORT:=8081}"
: "${BASIC_AUTH_USER:=user}"
: "${BASIC_AUTH_PASSWORD:=123456}"
: "${ENCODER:=x264enc}"
#: "${DRI_NODE:=/dev/dri/renderD128}"
# 固定分辨率（偶数），避免浏览器全屏时把 xrdp :10 resize 成奇数导致 pixelflux 崩溃

echo "==> 检查虚拟环境"
if [ ! -f "$VENV/bin/activate" ]; then
    echo "找不到虚拟环境: $VENV"
    exit 1
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "==> 检查自签名证书"
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo "证书已存在，跳过生成: $CERT_FILE"
else
    echo "证书不存在，生成新的自签名证书..."
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 3650 -subj "/CN=selkies"
    echo "证书已生成: $CERT_FILE"
fi

echo "==> 设置 xrdp 显示环境变量"
export DISPLAY=:10
export XAUTHORITY=/var/run/xrdp/1000/Xauthority
if [ ! -r "$XAUTHORITY" ]; then
    echo "警告: 读不到 $XAUTHORITY，请确认 xrdp 会话是否在跑"
fi

echo "==> 启动 selkies (端口 $PORT)"
echo "    浏览器访问: https://52.122.3.12:$PORT/"
echo

exec selkies \
    --addr=0.0.0.0 --port="$PORT" \
    --enable-https=true \
    --https-cert="$CERT_FILE" \
    --https-key="$KEY_FILE" \
    --enable-basic-auth=true \
    --basic-auth-user="$BASIC_AUTH_USER" \
    --basic-auth-password="$BASIC_AUTH_PASSWORD" \
    --encoder="$ENCODER" \
    #--dri-node="$DRI_NODE" \
