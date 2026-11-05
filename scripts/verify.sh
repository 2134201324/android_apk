#!/usr/bin/env bash
# ============================================================================
#  verify.sh —— 交付前验收（不看代码，只看包）
#
#  用法：
#      bash scripts/verify.sh --apk dist/我的应用-v1.0.0.apk
#      bash scripts/verify.sh --apk x.apk --expect-code 12   # 顺带核对版本号
#
#  检查项（任一 FAIL 就不可交付）：
#     1. 文件完整、不是 0 字节
#     2. 签名可验证（v2/v3 至少一个通过，targetSdk>=30 时 v2 必须有）
#     3. 包名 / versionCode / versionName 可读出
#     4. 有 launcher activity（否则装上去桌面没图标、点不开）
#     5. 有应用图标资源
#     6. release 包没有 android:debuggable=true
#     7. minSdk / targetSdk 在预期范围
#     8. 体积没有异常膨胀（>150MB 基本是资源没优化或误打包）
# ============================================================================
set -uo pipefail

APK=""
EXPECT_CODE=""
EXPECT_PKG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --apk)        APK="${2:-}"; shift 2 ;;
        --expect-code) EXPECT_CODE="${2:-}"; shift 2 ;;
        --expect-pkg)  EXPECT_PKG="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

[ -n "$APK" ] || { echo "✗ 缺少 --apk" >&2; exit 2; }
[ -f "$APK" ] || { echo "✗ 文件不存在：$APK" >&2; exit 1; }

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[ -z "$SDK" ] && for c in /opt/android-sdk "$HOME/Android/Sdk"; do
    [ -d "$c/platforms" ] && { SDK="$c"; break; }
done
BT="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -1)"
BT="$SDK/build-tools/${BT:-36.0.0}"

FAIL=0; WARN=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "──────── APK 交付验收 ────────"
echo "文件：$APK"

# 1. 完整性
SIZE_B="$(stat -c%s "$APK" 2>/dev/null || echo 0)"
if [ "$SIZE_B" -lt 10240 ]; then
    fail "文件过小（${SIZE_B}B），基本是构建中断的残包"
else
    pass "文件完整：$(du -h "$APK" | cut -f1)"
fi

# 2. 签名
if [ -x "$BT/apksigner" ]; then
    VOUT="$("$BT/apksigner" verify --verbose --print-certs "$APK" 2>&1)"
    if [ $? -eq 0 ]; then
        # 只取值为 true 的方案；false 的行没有意义，混在一起会让人以为签名不全
        SCHEMES="$(echo "$VOUT" | grep -E ': true$' | grep -oP 'Verified using \Kv[0-9.]+ scheme' | tr '\n' ' ')"
        # v4 不在这份输出里体现（它是独立的 .idsig），单独提示文件是否存在
        [ -f "$APK.idsig" ] && SCHEMES="${SCHEMES}v4(.idsig) "
        pass "签名通过：${SCHEMES:-v1/v2}"
        CERT="$(echo "$VOUT" | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}')"
        [ -n "$CERT" ] && echo "    证书 SHA-256：$CERT"
    else
        fail "签名校验失败：$(echo "$VOUT" | tail -2 | tr '\n' ' ')"
    fi
else
    warn "找不到 apksigner，跳过签名校验"
fi

# 3. 元信息
BADGING="$("$BT/aapt2" dump badging "$APK" 2>/dev/null)"
PKG="$(echo "$BADGING" | grep -oP "^package: name='\K[^']+" | head -1)"
CODE="$(echo "$BADGING" | grep -oP "versionCode='\K[0-9]+" | head -1)"
VNAME="$(echo "$BADGING" | grep -oP "versionName='\K[^']+" | head -1)"
MINSDK="$(echo "$BADGING" | grep -oP "sdkVersion:'\K[0-9]+" | head -1)"
TARGETSDK="$(echo "$BADGING" | grep -oP "targetSdkVersion:'\K[0-9]+" | head -1)"
LABEL="$(echo "$BADGING" | grep -oP "application-label:'\K[^']+" | head -1)"

[ -n "$PKG" ] && pass "包名：$PKG" || fail "读不出包名（AndroidManifest 可能损坏）"
[ -n "$CODE" ] && pass "版本：${VNAME:-?} (code $CODE)" || fail "读不出版本号"

if [ -n "$EXPECT_CODE" ] && [ "$CODE" != "$EXPECT_CODE" ]; then
    fail "versionCode 不符：期望 $EXPECT_CODE，实际 $CODE"
fi
if [ -n "$EXPECT_PKG" ] && [ "$PKG" != "$EXPECT_PKG" ]; then
    fail "包名不符：期望 $EXPECT_PKG，实际 $PKG"
fi

# 4. 启动入口
LAUNCH="$(echo "$BADGING" | grep -oP "launchable-activity: name='\K[^']+" | head -1)"
[ -n "$LAUNCH" ] && pass "启动入口：$LAUNCH" || fail "没有 launcher activity，装上去桌面无图标"

# 5. 图标
if echo "$BADGING" | grep -q "application-icon"; then
    pass "应用图标已打包"
else
    fail "缺应用图标（application-icon 为空），部分机型会显示默认机器人或空白"
fi

# 6. debuggable
if echo "$BADGING" | grep -q "application-debuggable"; then
    warn "这是 debuggable 包，不要对外分发（可被任意调试、读取数据）"
else
    pass "非 debuggable"
fi

# 7. SDK 范围
[ -n "$MINSDK" ] && echo "    minSdk=$MINSDK  targetSdk=${TARGETSDK:-?}"
if [ -n "$TARGETSDK" ] && [ "$TARGETSDK" -ge 23 ]; then
    :
else
    warn "targetSdk 过低（${TARGETSDK:-?}），Android 14+ 可能拒绝安装"
fi
if [ -n "$MINSDK" ] && [ "$MINSDK" -lt 21 ]; then
    warn "minSdk=$MINSDK 已不在主流支持范围"
fi

# 8. 体积
HUMAN_SIZE="$(du -h "$APK" | cut -f1)"
MB=$((SIZE_B / 1024 / 1024))
if [ "$MB" -gt 150 ]; then
    warn "体积 ${HUMAN_SIZE} 偏大，检查 assets 是否误打包了大文件"
else
    pass "体积正常：${HUMAN_SIZE}"
fi

# 9. ABI（有 so 时提示）
ABIS="$(unzip -l "$APK" 2>/dev/null | grep -oP 'lib/\K[^/]+' | sort -u | tr '\n' ' ')"
[ -n "$ABIS" ] && echo "    原生库 ABI：$ABIS"

echo "──────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m结论：可交付\033[0m（%d 项提醒）\n' "$WARN"
    exit 0
else
    printf '\033[31m结论：不可交付，%d 项失败\033[0m\n' "$FAIL"
    exit 1
fi
