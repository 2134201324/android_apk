# 安装与使用

这个目录是一个自包含的 **Agent Skill**：把「从源码到可安装 APK」的完整流程、脚本、模板和踩坑记录打包在一起。任何支持 Skills 的 AI 助手放进对应目录就能直接接手。

---

## 一、放到哪里

| 环境 | 目录 |
|---|---|
| WorkBuddy / CodeBuddy | `~/.codebuddy/skills/android-apk-forge/` |
| Claude Code | `~/.claude/skills/android-apk-forge/` |
| 其他支持 `SKILL.md` 约定的框架 | 按其文档的 skills 根目录放置，保持目录名不变 |

解压后确认结构是：

```
android-apk-forge/
├── SKILL.md            ← 入口，AI 会先读这个
├── INSTALL.md          ← 本文件
├── references/         ← 按需深入（环境/踩坑/配方/清单/交接）
├── scripts/            ← 可执行脚本
└── templates/          ← 两套能直接编译的工程骨架
```

放好后，对 AI 说一句「用 android-apk-forge 帮我做一个 XXX 的 App」即可触发。

---

## 二、第一次用（3 条命令）

```bash
SKILL=~/.codebuddy/skills/android-apk-forge

bash $SKILL/scripts/doctor.sh          # 体检：缺什么会直接告诉你

bash $SKILL/scripts/init-project.sh \
  --name "我的应用" --pkg com.example.myapp \
  --template compose --dir /workspace/myapp

bash $SKILL/scripts/build.sh --project /workspace/myapp
```

最后一条会输出 `dist/我的应用-v1.0.0.apk` 和一个 `.idsig`。

---

## 三、三种典型用法

**1. 做一个原生 App**

```bash
init-project.sh --template compose ...
# 然后改 app/src/main/java/<包路径>/MainActivity.kt
```

**2. 把现成的网页/游戏变成 App**

```bash
init-project.sh --template webview ...
rm -rf 目标/app/src/main/assets/*
cp -r 你的网页/. 目标/app/src/main/assets/
```

**3. 接大模型做聊天客户端**

用 `compose` 模板，然后照 `references/app-recipes.md` 第 3 节的 SSE 骨架写。那块把「分帧、空 delta、历史图片压平、用户中断」四个必踩的坑都处理了。

---

## 四、脚本清单

| 脚本 | 作用 |
|---|---|
| `doctor.sh` | 环境体检，缺 JDK/SDK/build-tools 直接给修复命令 |
| `init-project.sh` | 从模板生成工程，包名/应用名/版本号一次替换到位 |
| `new-keystore.sh` | 生成项目专属签名密钥（每个项目只做一次） |
| `build.sh` | 构建 + 版本一致性校验 + zipalign + 签名 + 归档 |
| `verify.sh` | 交付验收，8 项检查，任一 FAIL 即不可交付 |
| `bump-version.sh` | 推进 versionCode/versionName |

所有脚本都支持 `--help`。

---

## 五、这套东西为什么值得用

它不是"文档集合"，是**把踩过的坑固化成默认值**：

- 模板的 `targetSdk=34`、`isMinifyEnabled=false`、`-Xmx4g + SerialGC` 都是经过翻车验证的选择；
- `build.sh` 里那条「产物 versionCode 与源码不一致就拒绝签名」的检查，挡住的是「文件名是新版、装上去是旧功能」这类极难排查的问题；
- `references/pitfalls.md` 的 20 条，每条都写了症状、根因和验证方式，不是泛泛而谈；
- `verify.sh` 检查的是「能不能装、能不能开」，不是「代码写得漂不漂亮」。

---

## 六、边界

- 只管**造包**。发 GitHub 用 `github-connector`，出 Word/Excel 用 office 相关技能，反编译别人的 APK 用逆向类技能。
- 不带 NDK / C++ 工具链。需要写 native 代码时，先装 NDK 再在 `app/build.gradle.kts` 里配 `externalNativeBuild`。
- 不处理上架 Google Play 的合规（targetSdk 年度要求、隐私清单、签名密钥托管）。侧载分发无此约束。
- **脚本按 Linux 环境编写**，依赖 GNU `grep -P` 和 `sed -i`。macOS 上需 `brew install grep` 并让它优先于系统 grep，或直接在 Linux 容器/沙盒里构建（推荐）。`doctor.sh` 会检测并明确报出这一项。
