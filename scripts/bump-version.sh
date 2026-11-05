#!/usr/bin/env bash
# ============================================================================
#  bump-version.sh —— 推进版本号（versionCode 必须严格递增）
#
#  用法：
#      bash scripts/bump-version.sh --project .              # 1.0.0 → 1.0.1，code +1
#      bash scripts/bump-version.sh --project . --minor      # 1.0.1 → 1.1.0
#      bash scripts/bump-version.sh --project . --major      # 1.1.0 → 2.0.0
#      bash scripts/bump-version.sh --project . --set 1.4.2  # 指定版本名，code 仍 +1
#
#  为什么必须递增 versionCode：Android 用 versionName 展示、用 versionCode 判断
#  「是不是新版本」。code 不变时，即使 versionName 变了，安装器也会认为
#  「已安装同一版本」而拒绝覆盖（用户看到的是「应用未安装」）。
# ============================================================================
set -euo pipefail

PROJECT="."
KIND="patch"
SET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="${2:-}"; shift 2 ;;
        --major)   KIND="major"; shift ;;
        --minor)   KIND="minor"; shift ;;
        --patch)   KIND="patch"; shift ;;
        --set)     KIND="set"; SET="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

PROJECT="$(cd "$PROJECT" && pwd)"
GRADLE_FILE="$PROJECT/app/build.gradle.kts"
[ -f "$GRADLE_FILE" ] || GRADLE_FILE="$PROJECT/app/build.gradle"
[ -f "$GRADLE_FILE" ] || { echo "✗ 找不到 app/build.gradle(.kts)" >&2; exit 1; }

OLD_NAME="$(grep -oP 'versionName\s*=?\s*"\K[^"]+' "$GRADLE_FILE" | head -1)"
OLD_CODE="$(grep -oP 'versionCode\s*=?\s*\K[0-9]+' "$GRADLE_FILE" | head -1)"
[ -n "$OLD_NAME" ] && [ -n "$OLD_CODE" ] || { echo "✗ 读不到当前版本号" >&2; exit 1; }

IFS='.' read -r MAJ MIN PAT <<< "$OLD_NAME"
MAJ="${MAJ:-0}"; MIN="${MIN:-0}"; PAT="${PAT:-0}"

case "$KIND" in
    major) MAJ=$((MAJ+1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN+1)); PAT=0 ;;
    patch) PAT=$((PAT+1)) ;;
    set)   IFS='.' read -r MAJ MIN PAT <<< "$SET" ;;
esac

NEW_NAME="$MAJ.$MIN.$PAT"
NEW_CODE=$((OLD_CODE+1))

# 去掉版本名里可能存在的 -beta 后缀等，只保留数字段
NEW_NAME="$(echo "$NEW_NAME" | grep -oE '^[0-9]+(\.[0-9]+){0,2}' || echo "$NEW_NAME")"

sed -i -E "s|versionName = \"[^\"]*\"|versionName = \"$NEW_NAME\"|; s|versionName \"[^\"]*\"|versionName \"$NEW_NAME\"|" "$GRADLE_FILE"
sed -i -E "s|versionCode = [0-9]+|versionCode = $NEW_CODE|; s|versionCode [0-9]+|versionCode $NEW_CODE|" "$GRADLE_FILE"

echo "✓ 版本：$OLD_NAME ($OLD_CODE) → $NEW_NAME ($NEW_CODE)"
echo "  文件：$GRADLE_FILE"
