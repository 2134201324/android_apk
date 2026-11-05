#!/usr/bin/env bash
# ============================================================================
#  init-project.sh —— 从模板生成一个可立即构建的 Android 工程
#
#  用法：
#     bash scripts/init-project.sh --name "记账本" --pkg com.acme.ledger \
#         --template compose --dir /workspace/ledger
#
#  参数：
#     --name      应用显示名（可中文，会进桌面图标下方）
#     --pkg       包名，必须形如 com.company.app（全小写，至少两段）
#     --template compose | webview       默认 compose
#     --dir       目标目录（不存在会自动创建；非空目录会拒绝，防覆盖）
#     --version-name / --version-code    默认 1.0.0 / 1
#     --force     目标目录非空也继续（会覆盖同名文件，慎用）
#
#  做完这一步就可以直接 build.sh，模板本身是能编译通过的，
#  先拿到一个「装上能开」的包，再往里填业务，比一上来写一堆代码再调构建稳得多。
# ============================================================================
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAME=""
PKG=""
TEMPLATE="compose"
DIR=""
VERSION_NAME="1.0.0"
VERSION_CODE="1"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --name)         NAME="${2:-}"; shift 2 ;;
        --pkg)          PKG="${2:-}"; shift 2 ;;
        --template)     TEMPLATE="${2:-}"; shift 2 ;;
        --dir)          DIR="${2:-}"; shift 2 ;;
        --version-name) VERSION_NAME="${2:-}"; shift 2 ;;
        --version-code) VERSION_CODE="${2:-}"; shift 2 ;;
        --force)        FORCE=1; shift ;;
        -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
    esac
done

die() { echo "✗ $*" >&2; exit 1; }

[ -n "$NAME" ] || die "缺少 --name"
[ -n "$PKG" ]  || die "缺少 --pkg"
[ -n "$DIR" ]  || die "缺少 --dir"
[ "$TEMPLATE" = "compose" ] || [ "$TEMPLATE" = "webview" ] || die "--template 只能是 compose 或 webview"

# 包名规则：至少两段、全小写、每段字母开头，不能有 Java 关键字
echo "$PKG" | grep -qE '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' \
    || die "包名不合法：$PKG（应形如 com.company.app，全小写，至少两段）"
case ".$PKG." in
    *.int.*|*.class.*|*.new.*|*.if.*|*.for.*|*.do.*|*.null.*|*.true.*|*.false.*)
        die "包名里不能出现 Java 关键字：$PKG" ;;
esac

SRC="$SKILL_DIR/templates/$TEMPLATE-app"
[ -d "$SRC" ] || die "模板不存在：$SRC"

if [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ] && [ "$FORCE" != "1" ]; then
    die "目标目录非空：$DIR（确认要覆盖请加 --force）"
fi

mkdir -p "$DIR"
PKG_PATH="$(echo "$PKG" | tr '.' '/')"
ROOT_NAME="$(basename "$DIR" | tr -cd 'A-Za-z0-9_-')"
[ -n "$ROOT_NAME" ] || ROOT_NAME="App"

echo "==> 复制模板 [$TEMPLATE] → $DIR"
cp -a "$SRC/." "$DIR/"

echo "==> 写入包名 / 应用名"
# 只处理文本文件；png/jar 这类二进制不动。
# 用 -print0 防文件名带空格（模板里目前没有，但接手者可能加）。
find "$DIR" -type f \( -name '*.kt' -o -name '*.kts' -o -name '*.xml' -o -name '*.properties' \) -print0 \
    | while IFS= read -r -d '' f; do
        sed -i \
            -e "s|__PKG_PATH__|$PKG_PATH|g" \
            -e "s|__PKG__|$PKG|g" \
            -e "s|__APP_NAME__|$NAME|g" \
            -e "s|__ROOT_NAME__|$ROOT_NAME|g" \
            "$f"
    done

# 占位目录 → 真实包路径目录
if [ -d "$DIR/app/src/main/java/__PKG_PATH__" ]; then
    mkdir -p "$DIR/app/src/main/java/$PKG_PATH"
    mv "$DIR/app/src/main/java/__PKG_PATH__/"* "$DIR/app/src/main/java/$PKG_PATH/" 2>/dev/null || true
    rmdir "$DIR/app/src/main/java/__PKG_PATH__" 2>/dev/null || true
fi

echo "==> 版本号：$VERSION_NAME ($VERSION_CODE)"
sed -i -E "s|versionCode = [0-9]+|versionCode = $VERSION_CODE|" "$DIR/app/build.gradle.kts"
sed -i -E "s|versionName = \"[^\"]*\"|versionName = \"$VERSION_NAME\"|" "$DIR/app/build.gradle.kts"

# 把本机真实 JDK 路径写进 gradle.properties。
# 不写死模板里的路径，是因为换一台机器（macOS / 另一个镜像）时那个路径根本不存在，
# Gradle 会直接报 "Java home supplied is invalid"，而这个错误看起来像环境坏了，
# 实际只是路径没换。
echo "==> 固定 JDK 路径"
JH="${JAVA_HOME:-}"
if [ -z "$JH" ] && command -v javac >/dev/null 2>&1; then
    JAVAC_REAL="$(readlink -f "$(command -v javac)" 2>/dev/null || command -v javac)"
    JH="$(cd "$(dirname "$JAVAC_REAL")/.." && pwd -P)"
fi
if [ -n "$JH" ] && [ -x "$JH/bin/javac" ]; then
    MAJOR="$("$JH/bin/javac" -version 2>&1 | grep -oP '\K[0-9]+' | head -1)"
    if [ "${MAJOR:-0}" -ge 17 ]; then
        if grep -qE '^#?\s*org\.gradle\.java\.home=' "$DIR/gradle.properties"; then
            sed -i -E "s|^#?\s*org\.gradle\.java\.home=.*|org.gradle.java.home=$JH|" "$DIR/gradle.properties"
        else
            printf '\norg.gradle.java.home=%s\n' "$JH" >> "$DIR/gradle.properties"
        fi
        echo "  $JH（Java $MAJOR）"
    else
        echo "  ! $JH 是 Java ${MAJOR:-?}，低于 17；不写入，构建时会用系统默认 java"
    fi
else
    echo "  ! 没找到 JDK，跳过（构建前请先跑 doctor.sh）"
fi

echo "==> 补齐工程周边"
mkdir -p "$DIR/signing" "$DIR/dist"
chmod +x "$DIR/gradlew" 2>/dev/null || true

# 按应用名生成专属图标（图形与配色由名字哈希决定，每个项目都不一样）。
# 没有 Pillow 时静默退回模板自带的通用图标 —— 图标不该成为构建的阻塞项。
if command -v python3 >/dev/null 2>&1; then
    echo "==> 生成应用图标"
    if python3 "$SKILL_DIR/scripts/make-icon.py" --name "$NAME" --res "$DIR/app/src/main/res"; then
        rm -f "$DIR/app/src/main/res/drawable/ic_launcher_foreground.xml"
    else
        echo "  ! 跳过（缺少 Pillow）。装一下即可：pip3 install pillow"
    fi
fi

cat > "$DIR/.gitignore" <<'EOF'
# 构建产物
build/
.gradle/
dist/
local.properties
*.apk
*.idsig

# 签名密钥：绝不入库
signing/
*.keystore
*.jks
keystore.properties

# IDE
.idea/
*.iml
.DS_Store
EOF

# 应用图标提示：模板自带一个通用图标，换掉它只需替换这些 png。
cat > "$DIR/README.md" <<EOF
# $NAME

包名：\`$PKG\`　模板：\`$TEMPLATE\`

## 构建

\`\`\`bash
bash ~/.codebuddy/skills/android-apk-forge/scripts/build.sh \\
  --project "$(pwd)/$(basename "$DIR")" \\
  --version-name $VERSION_NAME --version-code $VERSION_CODE
\`\`\`

## 改哪里

- 应用名：\`app/src/main/res/values/strings.xml\`
- 图标：\`app/src/main/res/mipmap-*dpi/ic_launcher.png\`（5 个尺寸同名替换）
- 入口：\`app/src/main/java/$PKG_PATH/MainActivity.kt\`
- 网页资源（仅 webview 模板）：\`app/src/main/assets/index.html\`
- 版本号：\`app/build.gradle.kts\`（或直接用 bump-version.sh）

## 首次运行

\`\`\`bash
cd "$(basename "$DIR")" && ./gradlew assembleDebug
# 或直接出可分发 release 包：
bash ~/.codebuddy/skills/android-apk-forge/scripts/build.sh --project .
\`\`\`
EOF

echo
echo "✓ 工程已生成：$DIR"
echo "  下一步："
echo "    1) 写代码：$DIR/app/src/main/java/$PKG_PATH/MainActivity.kt"
if [ "$TEMPLATE" = "webview" ]; then
    echo "      或直接替换网页：$DIR/app/src/main/assets/index.html"
fi
echo "    2) 建签名密钥（只需一次）：bash $SKILL_DIR/scripts/new-keystore.sh --project $DIR"
echo "    3) 出包：bash $SKILL_DIR/scripts/build.sh --project $DIR"
