---
name: android-apk-forge
description: 从零产出可安装的 Android APK，并把整套流水线交给任何 AI 接手。当用户要求「做个 App / 打包成 APK / 把这个网页做成安卓应用 / 生成安卓软件 / 上架前出安装包 / 修构建或签名失败」时使用。覆盖环境体检、脚手架生成（原生 Compose / WebView 套壳 / AI 客户端 / 小游戏 / 数据类应用）、构建、zipalign、v2+v3 签名、产物校验、版本推进，以及 20 条真实踩坑的根因与修法。产出物是可直接分发、可覆盖升级的 .apk。
version: "1.0.0"
author: "WorkBuddy"
license: "MIT"
allowed-tools: [Read, Write, Edit, Bash, Glob, Grep]
---

# Android APK Forge

**目标**：任何 AI 接手后，不需要重新摸索环境、不需要猜构建参数，就能在半小时内（含首次依赖下载）产出一个能装、能开、能覆盖升级的 APK。缓存命中时，一次完整构建约 20 秒。

**唯一验收标准**：`apksigner verify` 通过 + `aapt2 dump badging` 的 versionCode 与源码一致 + 真机/模拟器能启动到首屏。三条缺一条就不算交付。

**实测基线**（本机 32 核 / 123GB，Gradle 缓存命中）：`compose` 模板首次构建 1 分 32 秒、产物 5.9MB；`webview` 模板 1 分 55 秒、产物 1.7MB。两者都通过 `verify.sh` 的 8 项检查。换环境时用这个数判断"是不是卡住了"：超过 10 分钟没有新日志，按 `references/environment.md` 第 5 节查内存。

> 需要把技能装到别的 AI 环境：见 `INSTALL.md`。

---

## 0. 先做判断：这个需求该用哪种形态

| 需求特征 | 选型 | 模板 | 理由 |
|---|---|---|---|
| 需要原生手感、系统能力（通知/后台/文件/权限） | 原生 Compose | `templates/compose-app` | 唯一能拿到完整系统 API 的路线 |
| 已有 HTML/JS 成品、要快速变成 App | WebView 套壳 | `templates/webview-app` | 2 小时出包，改动只在 `assets/` |
| 要接大模型、流式输出、工具调用 | 原生 Compose + OkHttp | `compose-app` + `references/app-recipes.md` §3 | WebView 做流式解析和会话持久化很痛苦 |
| 2D 小游戏、像素风 | WebView + Canvas | `webview-app` + recipes §5 | HTML5 Canvas 迭代最快；真要原生再用 Compose Canvas |
| 纯离线工具（记账/清单/计算） | 原生 Compose + DataStore | `compose-app` + recipes §4 | 无需网络权限，包体可压到 3MB 内 |
| 只是"想试试"、没有明确形态 | 原生 Compose | `compose-app` | 后续加页面成本最低 |

**不要做的事**：不要为了"显得专业"上 Flutter / React Native / KMP。这些在本环境里要么没装、要么首次构建要拉几 GB 依赖，失败率高且排查成本远超收益。原生 Compose 的模板已经验证过。

---

## 1. 执行流程（照抄，不要跳步）

```bash
# 装在别处时（Claude Code 等）换成实际路径，脚本内部全部按自身位置定位资源
SKILL=~/.codebuddy/skills/android-apk-forge

# ① 环境体检：缺什么会直接告诉你装什么
bash $SKILL/scripts/doctor.sh

# ② 生成项目骨架（模板 + 包名 + 应用名一次替换到位）
#    同时按应用名哈希生成一套专属图标（6 种图形 × 6 套配色），
#    所以每个新应用在桌面上都不一样，不会全是同一个默认图标。
bash $SKILL/scripts/init-project.sh \
  --name "我的应用" \
  --pkg com.example.myapp \
  --template compose \
  --dir /workspace/myapp

# ③ 写业务代码（唯一需要你创造力的地方，其余全是自动的）
#    入口：app/src/main/java/<包路径>/MainActivity.kt

# ④ 一键构建 + 对齐 + 签名 + 校验 + 归档
bash $SKILL/scripts/build.sh --project /workspace/myapp --version-name 1.0.0 --version-code 1
#    产物：/workspace/myapp/dist/<应用名>-v1.0.0.apk

# ⑤ 交付前跑验收
bash $SKILL/scripts/verify.sh --apk /workspace/myapp/dist/<应用名>-v1.0.0.apk
```

`build.sh` 内部已串好 Gradle → zipalign → apksigner(v2+v3+v4) → 指纹核对 → 版本一致性校验 → 产物归档。**不要绕过它手工拼命令**，手工拼最容易漏掉 versionCode 校验，从而签出"文件名是新版、内容是旧版"的包。

---

## 2. 三条硬约束（违反必炸，且炸得很晚）

1. **签名密钥必须固定并随项目交付**。换钥匙 = 用户无法覆盖安装 = 必须卸载重装 = 数据全丢。首次为新项目建钥匙用 `scripts/new-keystore.sh`，之后**永不更换**，并把它放进交付包（私有）。
2. **versionCode 必须严格递增**。Android 只认这个数字，同 code 不同内容装不上去。每次交付前用 `scripts/bump-version.sh`。
3. **`targetSdk` 是产品决策，不是越高越好**。要执行应用私有目录里的二进制（内置终端、自带运行时）就必须 `targetSdk <= 28`；纯 UI 应用用 34/35 没问题。改这个值之前先读 `references/pitfalls.md` 第 1 条。

---

## 3. 目录约定（模板已生成，不要改）

```
myapp/
├── app/
│   ├── build.gradle.kts          # versionCode / versionName / targetSdk 在这里
│   ├── proguard-rules.pro        # R8 反射保活
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/<pkg>/MainActivity.kt
│       ├── res/                  # 图标、主题、字符串
│       └── assets/               # WebView 模板的 HTML/JS 放这里
├── gradle/wrapper/               # 已锁定 Gradle 8.14.3
├── gradle.properties             # JDK 路径 + 内存参数，已调好
├── local.properties              # sdk.dir=/opt/android-sdk
├── signing/                      # 项目专属签名密钥（.gitignore 排除）
└── dist/                         # 构建产物归档
```

---

## 4. 按需深入（不要一次全读，按当前卡点读）

| 你在做什么 | 读这个 |
|---|---|
| 第一次在本机构建 / 报 JDK、SDK、Gradle 错 | `references/environment.md` |
| 构建失败、闪退、白屏、图标不对、签名冲突 | `references/pitfalls.md`（20 条，按症状查） |
| 要写聊天客户端 / 数据持久化 / 游戏 / 后台任务 | `references/app-recipes.md` |
| 准备交付给用户 | `references/release-checklist.md` |
| 要交接给下一个 AI | `references/handoff-template.md` |

---

## 5. 一次性交付清单（打印出来对照）

- [ ] `doctor.sh` 全绿
- [ ] `build.sh` 输出 `BUILD SUCCESSFUL` 且 `apksigner verify` 通过
- [ ] `aapt2 dump badging` 显示 `versionCode` 与源码一致
- [ ] 应用图标已生成或替换（`init-project.sh` 生成的图标不够贴题时，直接覆盖 5 个 `mipmap-*dpi/ic_launcher.png`）
- [ ] 首次启动无白屏、无权限崩溃
- [ ] 断网启动不崩（有网功能给出可读提示）
- [ ] 包体在预期范围（纯工具 <15MB，带 WebView 资源 <30MB）
- [ ] `dist/` 里的 APK + 签名密钥 + 源码 + 本文件已归入交付 ZIP

---

## 6. 与其他技能的边界

- 需要把 APK 发到 GitHub / 工蜂：用 `github-connector` / `gongfeng-connector`，本技能只产包。
- 需要生成 Word/Excel/PPT 交付文档：走 `workbuddy-office-routing`，不要用本技能硬塞。
- 需要反编译别人的 APK：用 `reverse-engineer-anything`，本技能只管"造"。
