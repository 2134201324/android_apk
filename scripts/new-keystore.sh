#!/usr/bin/env bash
# ============================================================================
#  new-keystore.sh —— 为工程生成一把专属签名密钥（每个项目只做一次）
#
#  用法：
#     bash scripts/new-keystore.sh --project /workspace/myapp
#     bash scripts/new-keystore.sh --project . --cn "Acme Studio" --alias acme
#
#  ⚠️ 这把钥匙决定了「能不能覆盖安装」。丢了它，已装用户只能卸载重装（数据清空）。
#     生成后请立刻把 signing/ 整个目录备份到安全位置，并且永远不要提交到公开仓库。
#
#  有效期默认 30 年（10950 天）。Google Play 要求至少到 2033 年，
#  纯侧载分发也建议一次给够，避免几年后被迫换钥匙。
# ============================================================================
set -euo pipefail

PROJECT=""
ALIAS="release"
PASS=""
CN="Android App"
VALIDITY=10950

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="${2:-}"; shift 2 ;;
        --alias)   ALIAS="${2:-}"; shift 2 ;;
        --pass)    PASS="${2:-}"; shift 2 ;;
        --cn)      CN="${2:-}"; shift 2 ;;
        --days)    VALIDITY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

[ -n "$PROJECT" ] || { echo "✗ 缺少 --project" >&2; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd)" || { echo "✗ 工程目录不存在" >&2; exit 1; }

KS_DIR="$PROJECT/signing"
KS="$KS_DIR/release.keystore"
PROPS="$KS_DIR/keystore.properties"

if [ -f "$KS" ]; then
    echo "! 已存在密钥：$KS"
    echo "  不会覆盖。要换钥匙请先手动备份并删除它 —— 换钥匙会让老用户无法覆盖安装。"
    keytool -list -v -keystore "$KS" -storepass "$(grep -oP 'storePassword=\K.*' "$PROPS" 2>/dev/null || echo android)" 2>/dev/null \
        | grep -E '别名|Alias|SHA256' | head -4 || true
    exit 0
fi

# 默认口令只用于本地自签分发；上架或对外发布请用 --pass 指定强口令。
if [ -z "$PASS" ]; then
    PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    echo "==> 已生成随机口令（会写进 signing/keystore.properties，权限 600）"
fi

mkdir -p "$KS_DIR"

echo "==> 生成 RSA 2048 密钥（有效期 ${VALIDITY} 天）"
keytool -genkeypair -v \
    -keystore "$KS" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 \
    -validity "$VALIDITY" \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=$CN, OU=Mobile, O=$CN, C=CN" \
    >/dev/null 2>&1 || {
        echo "✗ keytool 失败。确认 JDK 已安装且 --pass 至少 6 位。" >&2
        exit 1
    }

cat > "$PROPS" <<EOF
# 签名配置。这是机密文件：不要提交到任何仓库、不要发给外部人员。
# build.sh 会自动读取本文件；字段名不要改。
storeFile=release.keystore
storePassword=$PASS
keyAlias=$ALIAS
keyPassword=$PASS
EOF
chmod 600 "$PROPS" "$KS"

echo
echo "✓ 密钥已生成：$KS"
echo "  别名：$ALIAS"
echo "  口令：见 $PROPS（权限 600）"
echo
echo "  证书指纹（交付时记录下来，用于核对各版本是否同一把钥匙）："
keytool -list -v -keystore "$KS" -storepass "$PASS" -alias "$ALIAS" 2>/dev/null \
    | grep -E 'SHA1:|SHA256:' | sed 's/^/    /'
echo
echo "  ⚠️ 立刻备份 signing/ 目录。丢失后已安装用户无法覆盖升级。"
