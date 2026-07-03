#!/usr/bin/env bash
#
# 本机构建 Selkies Web 前端（selkies-web-core + selkies-dashboard），
# 复现官方 addons/selkies-web-core/Dockerfile 里的构建步骤，
# 最终把静态文件放到 src/selkies/selkies_web/，配合 `pip install -e .` 使用。
#
# 用法：
#   ./build-ui.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDONS="$ROOT/addons"
OUT="$ROOT/src/selkies/selkies_web"

# SELKIES_MODE / SELKIES_UPLOAD_DIR 可在调用前覆盖，默认值同官方 Dockerfile
: "${SELKIES_MODE:=webrtc}"
: "${SELKIES_UPLOAD_DIR:=$HOME/Desktop}"

echo "==> 检查构建依赖"
missing=()
for bin in node npm cmake git; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [ ${#missing[@]} -ne 0 ]; then
    echo "缺少依赖: ${missing[*]}"
    echo "请先安装，例如: sudo apt-get install -y cmake nodejs npm git"
    exit 1
fi

echo "==> [1/4] 构建 selkies-web-core"
cd "$ADDONS/selkies-web-core"
npm install
npm run build

echo "==> [2/4] 构建 selkies-dashboard（注入 selkies-web-core 产物）"
cd "$ADDONS/selkies-dashboard"
cp "$ADDONS/selkies-web-core/dist/selkies-core.js" src/
npm install
SELKIES_INJECT=1 SELKIES_MODE="$SELKIES_MODE" SELKIES_UPLOAD_DIR="$SELKIES_UPLOAD_DIR" \
    npm run build

echo "==> [3/4] 拼装最终静态目录"
mkdir -p dist/src dist/nginx dist/assets
cp "$ADDONS/selkies-web-core/dist/selkies-core.js" dist/src/
cp "$ADDONS/selkies-web-core/dist/clipboard-worker"* dist/assets/
cp "$ADDONS/universal-touch-gamepad/universalTouchGamepad.js" dist/src/
cp "$ADDONS/selkies-web-core/nginx/"* dist/nginx/
cp -r "$ADDONS/selkies-web-core/dist/jsdb" dist/

echo "==> [4/4] 安装到 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -ar dist/* "$OUT/"

cat > "$OUT/manifest.json" <<EOF
{
  "name": "Selkies",
  "short_name": "Selkies",
  "manifest_version": 2,
  "version": "1.0.0",
  "display": "fullscreen",
  "background_color": "#000000",
  "theme_color": "#000000",
  "icons": [{ "src": "icon.png", "type": "image/png", "sizes": "180x180" }],
  "start_url": "/"
}
EOF

# 图标是可选的（官方从网上下载 logo），本机构建默认跳过网络请求；
# 如需要可取消下面注释自行下载：
# curl -o "$OUT/icon.png" https://raw.githubusercontent.com/linuxserver/docker-templates/master/linuxserver.io/img/selkies-logo.png
# curl -o "$OUT/favicon.ico" https://raw.githubusercontent.com/linuxserver/docker-templates/refs/heads/master/linuxserver.io/img/selkies-icon.ico

echo
echo "构建完成: $OUT"
ls "$OUT"
