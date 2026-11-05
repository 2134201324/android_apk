#!/usr/bin/env bash
# ============================================================================
#  build.sh —— 一条命令从源码到可分发 APK
#
#  用法：
#     bash scripts/build.sh --project /workspace/myapp
#     bash scripts/build.sh --project . --version-name 1.2.0 --version-code 12
#     bash scripts/build.sh --project . --debug          # 只出 debug 包（快，用于验证能编译）
#     bash scripts/build.sh --project . --no-sign        # 只出 unsigned，调试签名问题用
#
#  它做的事（顺序不能换）：
#     1. 环境体检（缺 SDK/JDK 直接失败，不要等到 Gradle 报一堆看不懂的错）
#     2. 写入版本号（如传入）
#     3. 找/生成签名密钥
#     4. ./gradlew assembleRelease
#     5. **核对产物内的 versionCode 与源码一致** ← 防「文件名是新版、内容是旧版」
#     6. zipalign -p 4
#     7. apksigner（v2 + v3 + v4）
#     8. apksigner verify + aapt2 badging
#     9. 归档到 dist/<应用名>-v<version>.apk
#
#  为什么第 5 步是关键：Gradle 构建失败时不会删除上一次的产物，磁盘上还留着旧 APK。
#  这时如果按新版本号命名并签名，就会得到一个「版本号写着 1.2.0、实际代码是 1.1.0」
#  的包。装上去功能不对，排查方向会完全跑偏。这个坑真实踩过，所以做成硬校验。
# ============================================================================
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="."
VERSION_NAME=""
VERSION_CODE=""
MODE="release"
SIGN=1
ALLOW_STALE=0
CLEAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --project)      PROJECT="${2:-}"; shift 2 ;;
        --version-name) VERSION_NAME="${2:-}"; shift 2 ;;
        --version-code) VERSION_CODE="${2:-}"; shift 2 ;;
        --debug)        MODE="debug"; shift ;;
        --no-sign)      SIGN=0; shift ;;
        --clean)        CLEAN=1; shift ;;
        --allow-stale)  ALLOW_STALE=1; shift ;;
        -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "工程目录不存在"
[ -f "$PROJECT/settings.gradle.kts" ] || [ -f "$PROJECT/settings.gradle" ] \
    || die "$PROJECT 不是 Gradle 工程（缺 settings.gradle.kts）"
[ -x "$PROJECT/gradlew" ] || die "缺少 gradlew，或没有执行权限：chmod +x $PROJECT/gradlew"

GRADLE_FILE="$PROJECT/app/build.gradle.kts"
[ -f "$GRADLE_FILE" ] || GRADLE_FILE="$PROJECT/app/build.gradle"
[ -f "$GRADLE_FILE" ] || die "找不到 app/build.gradle(.kts)"

# ---------- SDK / build-tools ----------
step "定位 Android SDK"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[ -z "$SDK" ] && for c in /opt/android-sdk "$HOME/Android/Sdk" /usr/lib/android-sdk; do
    [ -d "$c/platforms" ] && { SDK="$c"; break; }
done
[ -n "$SDK" ] && [ -d "$SDK" ] || die "找不到 Android SDK。装好后重试，或 export ANDROID_SDK_ROOT=..."
BT="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || die "找不到 build-tools。sdkmanager 'build-tools;34.0.0'"
BT="$SDK/build-tools/$BT"
for t in aapt2 zipalign apksigner; do
    [ -x "$BT/$t" ] || die "build-tools 里缺 $t：$BT"
done
echo "  SDK: $SDK"
echo "  build-tools: $(basename "$BT")"

# local.properties 必须指向真实 SDK，否则换个沙盒就构建失败
if ! grep -q "^sdk.dir=" "$PROJECT/local.properties" 2>/dev/null; then
    echo "sdk.dir=$SDK" > "$PROJECT/local.properties"
    echo "  已写入 local.properties"
fi

# ---------- 版本号 ----------
if [ -n "$VERSION_NAME" ]; then
    sed -i -E "s|versionName = \"[^\"]*\"|versionName = \"$VERSION_NAME\"|; s|versionName \"[^\"]*\"|versionName \"$VERSION_NAME\"|" "$GRADLE_FILE"
fi
if [ -n "$VERSION_CODE" ]; then
    sed -i -E "s|versionCode = [0-9]+|versionCode = $VERSION_CODE|; s|versionCode [0-9]+|versionCode $VERSION_CODE|" "$GRADLE_FILE"
fi

VNAME="$(grep -oP 'versionName\s*=?\s*"\K[^"]+' "$GRADLE_FILE" | head -1)"
VCODE="$(grep -oP 'versionCode\s*=?\s*\K[0-9]+' "$GRADLE_FILE" | head -1)"
[ -n "$VNAME" ] && [ -n "$VCODE" ] || die "读不到 versionName/versionCode，检查 $GRADLE_FILE"
echo "  版本：$VNAME ($VCODE)"

# ---------- 签名密钥 ----------
KS=""; KS_PASS=""; KS_ALIAS=""; KS_KEY_PASS=""
if [ "$SIGN" = "1" ]; then
    step "准备签名密钥"
    PROPS="$PROJECT/signing/keystore.properties"
    if [ -f "$PROPS" ]; then
        KS="$PROJECT/signing/$(grep -oP '^storeFile=\K.*' "$PROPS" | head -1)"
        KS_PASS="$(grep -oP '^storePassword=\K.*' "$PROPS" | head -1)"
        KS_ALIAS="$(grep -oP '^keyAlias=\K.*' "$PROPS" | head -1)"
        KS_KEY_PASS="$(grep -oP '^keyPassword=\K.*' "$PROPS" | head -1)"
        echo "  使用已有密钥：$KS"
    elif [ -f "$PROJECT/signing/release.keystore" ]; then
        KS="$PROJECT/signing/release.keystore"
        KS_PASS="android"; KS_ALIAS="release"; KS_KEY_PASS="android"
        echo "  使用已有密钥（无配置文件，按默认口令）：$KS"
    else
        echo "  未找到密钥，自动生成一把项目专属密钥"
        # dname 里出现逗号会破坏 "CN=x, O=y" 的结构，中文也会在部分 keytool 版本上报错，
        # 所以只保留 ASCII 安全字符；空则回落到通用名。
        CN_SAFE="$(basename "$PROJECT" | tr -cd 'A-Za-z0-9._-')"
        [ -n "$CN_SAFE" ] || CN_SAFE="Android App"
        bash "$SKILL_DIR/scripts/new-keystore.sh" --project "$PROJECT" --cn "$CN_SAFE" >/dev/null
        PROPS="$PROJECT/signing/keystore.properties"
        KS="$PROJECT/signing/$(grep -oP '^storeFile=\K.*' "$PROPS" | head -1)"
        KS_PASS="$(grep -oP '^storePassword=\K.*' "$PROPS" | head -1)"
        KS_ALIAS="$(grep -oP '^keyAlias=\K.*' "$PROPS" | head -1)"
        KS_KEY_PASS="$(grep -oP '^keyPassword=\K.*' "$PROPS" | head -1)"
    fi
    [ -f "$KS" ] || die "密钥文件不存在：$KS"
    echo "  别名：$KS_ALIAS"
fi

# ---------- 构建 ----------
step "Gradle 构建（$MODE）"
[ "$CLEAN" = "1" ] && { echo "  clean..."; (cd "$PROJECT" && ./gradlew clean -q) || true; }

TASK=$([ "$MODE" = "debug" ] && echo "assembleDebug" || echo "assembleRelease")
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT

set +e
(cd "$PROJECT" && ./gradlew "$TASK" --console=plain --stacktrace 2>&1) | tee "$BUILD_LOG"
RC=${PIPESTATUS[0]}
set -e

if [ "$RC" -ne 0 ]; then
    echo
    echo "──────── 构建失败：常见根因速查 ────────"
    if grep -qE 'Unsupported class file major version|invalid source release|Unsupported Java' "$BUILD_LOG"; then
        echo "  · JDK 版本不匹配 → 改 gradle.properties 的 org.gradle.java.home"
    elif grep -qE 'Could not resolve|Could not download|Connection timed out' "$BUILD_LOG"; then
        echo "  · 依赖下载失败 → 检查网络；或先在有网环境跑一次让缓存落地"
    elif grep -qE 'Daemon disappeared|OutOfMemoryError|GC overhead' "$BUILD_LOG"; then
        echo "  · 内存不足 → 调大 gradle.properties 的 -Xmx（4g → 8g），保持 SerialGC"
    elif grep -qE "Unresolved reference|None of the following functions|Type mismatch" "$BUILD_LOG"; then
        echo "  · Kotlin 编译错误 → 看日志里第一条 error，后面的多半是连锁反应"
    elif grep -qE 'Duplicate class|Manifest merger failed' "$BUILD_LOG"; then
        echo "  · 依赖冲突 / Manifest 合并冲突 → 看日志里的 Duplicate class 或 merger 明细"
    else
        echo "  · 先看日志里第一个 FAILURE/error，不要从最后一行倒着读"
    fi
    echo "  · 详细排查：references/pitfalls.md"
    echo "────────────────────────────────────────"
    exit 1
fi

# ---------- 找产物 ----------
step "定位产物"
if [ "$MODE" = "debug" ]; then
    APK="$(find "$PROJECT/app/build/outputs/apk/debug" -name '*.apk' -newermt '-30 minutes' 2>/dev/null | head -1)"
    [ -n "$APK" ] || APK="$(find "$PROJECT/app/build/outputs/apk/debug" -name '*.apk' 2>/dev/null | head -1)"
else
    APK="$(find "$PROJECT/app/build/outputs/apk/release" -name '*unsigned*.apk' 2>/dev/null | head -1)"
    [ -n "$APK" ] || APK="$(find "$PROJECT/app/build/outputs/apk/release" -name '*.apk' 2>/dev/null | head -1)"
fi
[ -n "$APK" ] || die "构建成功但找不到 APK，检查 app/build/outputs/apk/"
echo "  $APK"

# ---------- 版本一致性硬校验 ----------
step "校验产物版本"
APK_CODE="$("$BT/aapt2" dump badging "$APK" 2>/dev/null | grep -oP "versionCode='\K[0-9]+" | head -1)"
APK_NAME="$("$BT/aapt2" dump badging "$APK" 2>/dev/null | grep -oP "versionName='\K[^']+" | head -1)"
echo "  产物内：$APK_NAME ($APK_CODE)　源码：$VNAME ($VCODE)"
if [ "$APK_CODE" != "$VCODE" ]; then
    if [ "$ALLOW_STALE" = "1" ]; then
        echo "  ! versionCode 不一致，但已指定 --allow-stale，继续"
    else
        die "产物 versionCode 与源码不一致 → 这次 assemble 没有真正产出新包（构建失败或被缓存挡住）。先 --clean 重跑。"
    fi
fi

# ---------- 应用名 / 包名 ----------
PKG_LINE="$("$BT/aapt2" dump badging "$APK" 2>/dev/null | grep -oP "^package: name='\K[^']+")"
APP_LABEL="$("$BT/aapt2" dump badging "$APK" 2>/dev/null | grep -oP "application-label:'\K[^']+" | head -1)"
SAFE_NAME="$(echo "${APP_LABEL:-app}" | tr -d '/\\:*?"<>|' | tr ' ' '_')"
[ -n "$SAFE_NAME" ] || SAFE_NAME="app"

# ---------- 签名 ----------
mkdir -p "$PROJECT/dist"
if [ "$SIGN" = "1" ]; then
    step "zipalign + 签名"
    ALIGN_DIR="$(mktemp -d)"
    ALIGNED="$ALIGN_DIR/aligned.apk"
    "$BT/zipalign" -p -f 4 "$APK" "$ALIGNED"

    OUT="$PROJECT/dist/${SAFE_NAME}-v${VNAME}.apk"
    "$BT/apksigner" sign \
        --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_KEY_PASS" --ks-key-alias "$KS_ALIAS" \
        --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled true \
        --out "$OUT" "$ALIGNED"
    rm -rf "$ALIGN_DIR"

    step "校验签名"
    VERIFY_OUT="$("$BT/apksigner" verify --verbose --print-certs "$OUT" 2>&1)" \
        || die "签名校验失败，产物不可交付：$OUT"
    echo "  签名方案：$(echo "$VERIFY_OUT" | grep -E ': true$' | grep -oP 'v[0-9.]+ scheme' | tr '\n' ' ')"
    echo "  证书 SHA-256：$(echo "$VERIFY_OUT" | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}')"
else
    OUT="$PROJECT/dist/${SAFE_NAME}-v${VNAME}-unsigned.apk"
    cp "$APK" "$OUT"
    echo "  已跳过签名（--no-sign）"
fi

# ---------- 摘要 ----------
SIZE="$(du -h "$OUT" | cut -f1)"
step "完成"
echo "  文件：$OUT"
echo "  包名：$PKG_LINE"
echo "  版本：$VNAME ($VCODE)"
echo "  体积：$SIZE"
[ -f "$OUT.idsig" ] && echo "  v4 签名：$OUT.idsig"
echo
echo "  安装到已连接设备："
echo "    $SDK/platform-tools/adb install -r \"$OUT\""
