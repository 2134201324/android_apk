#!/usr/bin/env bash
# ============================================================================
#  doctor.sh —— 构建环境体检
#
#  用法：
#      bash scripts/doctor.sh            # 人类可读
#      bash scripts/doctor.sh --json     # 机器可读（给上层 Agent 判断）
#
#  退出码：0 全部就绪 / 1 有阻塞项（缺 JDK、SDK、build-tools、platform）
#
#  设计原则：只报告「缺什么 + 一条能直接执行的修复命令」，不打印一堆版本号
#  让人自己猜。首次接手一个陌生沙盒时，先跑这个，比盲目 gradle 快 10 倍。
# ============================================================================
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

FAIL=0
WARN=0
declare -a LINES

ok()   { LINES+=("OK|$1|$2"); }
warn() { LINES+=("WARN|$1|$2"); WARN=$((WARN+1)); }
bad()  { LINES+=("FAIL|$1|$2"); FAIL=$((FAIL+1)); }

# ---------- 1. JDK ----------
JDK_HOME=""
for c in "${JAVA_HOME:-}" /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-amd64; do
    [ -n "$c" ] && [ -x "$c/bin/javac" ] && { JDK_HOME="$c"; break; }
done
if [ -z "$JDK_HOME" ] && command -v javac >/dev/null 2>&1; then
    JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi

if [ -z "$JDK_HOME" ]; then
    bad "JDK" "未找到 JDK。装一个：sudo apt-get install -y openjdk-21-jdk"
else
    JV="$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
    MAJOR="$(echo "$JV" | grep -oP '"\K[0-9]+' | head -1)"
    if [ "${MAJOR:-0}" -ge 17 ]; then
        ok "JDK" "$JDK_HOME（Java $MAJOR）"
    else
        bad "JDK" "版本过低（$JV），AGP 8.x 需要 17+"
    fi
fi

# ---------- 2. Android SDK ----------
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[ -z "$SDK" ] && for c in /opt/android-sdk "$HOME/Android/Sdk" /usr/lib/android-sdk; do
    [ -d "$c/platforms" ] && { SDK="$c"; break; }
done

if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    bad "Android SDK" "未找到。装 cmdline-tools 后执行：sdkmanager 'platform-tools' 'platforms;android-34' 'build-tools;34.0.0'"
else
    ok "Android SDK" "$SDK"

    # build-tools：取最高版本，必须 >= 34（zipalign/apksigner/aapt2 都在里面）
    BT_DIR="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -1)"
    if [ -z "$BT_DIR" ]; then
        bad "build-tools" "目录为空。sdkmanager 'build-tools;34.0.0'"
    else
        BT_MAJOR="${BT_DIR%%.*}"
        if [ "${BT_MAJOR:-0}" -ge 34 ]; then
            ok "build-tools" "$BT_DIR"
        else
            warn "build-tools" "$BT_DIR 偏旧，建议 34+（新版 apksigner 才能出 v4 签名）"
        fi
    fi

    # platform：compileSdk 必须存在对应 android-XX
    PLAT="$(ls -1 "$SDK/platforms" 2>/dev/null | grep -oP 'android-\K[0-9]+' | sort -n | tail -1)"
    if [ -z "$PLAT" ]; then
        bad "platform" "没有任何 platform。sdkmanager 'platforms;android-34'"
    elif [ "$PLAT" -ge 34 ]; then
        ok "platform" "最高 android-$PLAT"
    else
        warn "platform" "最高 android-$PLAT，模板 compileSdk=35，需补装或下调 compileSdk"
    fi

    [ -x "$SDK/platform-tools/adb" ] && ok "platform-tools" "adb 可用" \
        || warn "platform-tools" "缺 adb（只影响真机安装，不影响出包）"
fi

# ---------- 3. Gradle ----------
GSYS="$(command -v gradle 2>/dev/null || true)"
if [ -n "$GSYS" ]; then
    GV="$("$GSYS" --version 2>/dev/null | grep -oP 'Gradle \K[0-9.]+' | head -1)"
    ok "Gradle(系统)" "${GV:-unknown} @ $GSYS"
else
    warn "Gradle(系统)" "未安装；模板自带 wrapper，首次构建会联网下载 8.14.3（约 130MB）"
fi

# wrapper 缓存是否已在本地（决定首次构建要不要等下载）
WRAP_HIT=0
[ -d "$HOME/.gradle/wrapper/dists" ] && \
    find "$HOME/.gradle/wrapper/dists" -maxdepth 2 -name "gradle-8.14.3*" 2>/dev/null | grep -q . && WRAP_HIT=1
[ "$WRAP_HIT" = "1" ] && ok "Gradle wrapper" "8.14.3 已缓存，可离线启动" \
    || warn "Gradle wrapper" "未缓存，首次构建需外网（services.gradle.org）"

# ---------- 4. 基础工具（脚本依赖 GNU 版 grep -P / sed -i） ----------
if echo "probe123" | grep -qP '\d+' 2>/dev/null; then
    ok "GNU grep" "支持 -P（脚本依赖）"
else
    fail "GNU grep" "当前 grep 不支持 -P（macOS 自带 BSD grep）。装 GNU 版并优先使用：brew install grep，或直接在 Linux 容器里构建"
fi

# ---------- 5. 资源 ----------
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
[ "${MEM_GB:-0}" -ge 4 ] && ok "内存" "${MEM_GB}GB" || bad "内存" "仅 ${MEM_GB}GB，R8 压缩阶段可能被 OOM 杀掉"

DISK_GB=$(df -BG /workspace 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
[ -z "${DISK_GB:-}" ] && DISK_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
[ "${DISK_GB:-0}" -ge 10 ] && ok "磁盘" "${DISK_GB}GB 可用" \
    || bad "磁盘" "仅 ${DISK_GB}GB，Gradle 缓存在首次构建时可能占 2-3GB"

# ---------- 5. 网络（只测能不能连，不阻塞） ----------
if command -v curl >/dev/null 2>&1; then
    if curl -sS -m 6 -o /dev/null -w "%{http_code}" https://dl.google.com/dl/android/maven2/ 2>/dev/null | grep -qE '^(200|301|302|403|404)$'; then
        ok "网络" "Maven 仓库可达"
    else
        warn "网络" "dl.google.com 不可达；若 Gradle 缓存已全量，仍可离线构建"
    fi
fi

# ---------- 输出 ----------
if [ "$JSON" = "1" ]; then
    printf '{"fail":%d,"warn":%d,"items":[' "$FAIL" "$WARN"
    first=1
    for l in "${LINES[@]}"; do
        st="${l%%|*}"; rest="${l#*|}"; k="${rest%%|*}"; v="${rest#*|}"
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"status":"%s","item":"%s","detail":"%s"}' "$st" "$k" "${v//\"/\\\"}"
    done
    printf ']}\n'
else
    echo "──────── Android APK 构建环境体检 ────────"
    for l in "${LINES[@]}"; do
        st="${l%%|*}"; rest="${l#*|}"; k="${rest%%|*}"; v="${rest#*|}"
        case "$st" in
            OK)   printf '  \033[32m✓\033[0m %-16s %s\n' "$k" "$v" ;;
            WARN) printf '  \033[33m!\033[0m %-16s %s\n' "$k" "$v" ;;
            FAIL) printf '  \033[31m✗\033[0m %-16s %s\n' "$k" "$v" ;;
        esac
    done
    echo "──────────────────────────────────────────"
    if [ "$FAIL" -eq 0 ]; then
        echo "结论：可构建（$WARN 项提醒不阻塞）"
    else
        echo "结论：有 $FAIL 项阻塞，按上面的修复命令处理后重跑本脚本"
    fi
fi

exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
