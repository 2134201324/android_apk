# 构建环境：从零到能出包

本文件只在两种情况下需要读：**换了台机器**，或 **`doctor.sh` 报了红**。日常出包直接跑 `build.sh` 就行。

---

## 1. 最小依赖清单

| 组件 | 版本 | 作用 | 不装的后果 |
|---|---|---|---|
| JDK | 17 或 21 | 跑 Gradle、keytool、apksigner 的 JVM | 一切都不动 |
| Android SDK Platform | `android-34` 或更高 | 提供 `android.jar`，compileSdk 指向它 | `Failed to find target with hash string 'android-34'` |
| Build-Tools | `34.0.0` 或更高 | aapt2 / zipalign / apksigner / d8 | 能编译不能签名 |
| Platform-Tools | 任意 | adb，装包到真机 | 只影响安装，不影响出包 |
| Gradle | 8.13+（模板自带 8.14.3 wrapper） | 构建 | 用 wrapper 就不需要系统装 |

**不需要**：Android Studio、NDK（除非写 C++）、模拟器。

---

## 2. 安装（Debian/Ubuntu 系）

```bash
# JDK
sudo apt-get update && sudo apt-get install -y openjdk-21-jdk unzip

# cmdline-tools
export ANDROID_SDK_ROOT=/opt/android-sdk
sudo mkdir -p $ANDROID_SDK_ROOT/cmdline-tools
cd /tmp && curl -fsSLO https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
sudo unzip -q commandlinetools-linux-*.zip -d $ANDROID_SDK_ROOT/cmdline-tools
sudo mv $ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools $ANDROID_SDK_ROOT/cmdline-tools/latest

# 组件（yes 自动接受 license）
yes | $ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_SDK_ROOT \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0"
```

把这两行写进 `~/.bashrc`，否则每次新 shell 都要重设：

```bash
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH=$PATH:$ANDROID_SDK_ROOT/platform-tools
```

---

## 3. 国内网络：依赖拉不下来时

Gradle 默认走 `dl.google.com` 和 `repo.maven.apache.org`。国内机器常见「卡在 Downloading」十几分钟然后超时。在**工程根目录**的 `settings.gradle.kts` 里把镜像放在最前面：

```kotlin
pluginManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google(); mavenCentral(); gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google(); mavenCentral()
    }
}
```

Gradle 本体下载慢，则改 `gradle/wrapper/gradle-wrapper.properties`：

```properties
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-8.14.3-bin.zip
```

---

## 4. 缓存与离线

Gradle 的依赖缓存在 `~/.gradle/caches/modules-2`。**同一个镜像里构建过一次，后续项目基本都能命中缓存**，所以第二次出包通常比第一次快 5–10 倍。

判断某个依赖是否已缓存：

```bash
ls ~/.gradle/caches/modules-2/files-2.1/androidx.compose/compose-bom
```

没有输出 = 需要联网。要离线构建，必须保证以下都在缓存里：

- `com.android.tools.build:gradle`
- `org.jetbrains.kotlin:kotlin-gradle-plugin`
- 工程 `dependencies {}` 里声明的每一个

---

## 5. 内存参数怎么定

`gradle.properties` 里的 `org.gradle.jvmargs` 不是越大越好。经验值：

| 工程规模 | 参数 |
|---|---|
| 模板 / 小应用（<100 个类） | `-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+UseSerialGC` |
| 中等（有 R8 + 多模块） | `-Xmx8g -XX:MaxMetaspaceSize=2g -XX:+UseSerialGC` |
| 大工程（几百个类、开了全量混淆） | `-Xmx12g`，`org.gradle.parallel=false` |

**判断依据不是「机器有多少内存」，而是「有没有出现 daemon 被杀」**：日志停在 `minifyReleaseWithR8` 或 `lintVitalAnalyzeRelease` 后进程直接消失、没有 BUILD SUCCESSFUL 也没有报错，就是被回收了。此时按上表加一档，保持 SerialGC（短命大内存场景比 G1 更抗回收）。

---

## 6. 报错 → 根因速查

| 报错片段 | 根因 | 修法 |
|---|---|---|
| `Unsupported class file major version` | Gradle 跑的 JDK 太新/太旧 | 在 `gradle.properties` 写死 `org.gradle.java.home` |
| `Failed to find target with hash string 'android-34'` | 没装对应 platform | `sdkmanager "platforms;android-34"`，或降 `compileSdk` |
| `SDK location not found` | 缺 `local.properties` | `echo "sdk.dir=/opt/android-sdk" > local.properties` |
| `Could not resolve ...` / `Connection timed out` | 网络/镜像 | 见第 3 节 |
| `Daemon disappeared unexpectedly` | 内存被回收 | 见第 5 节 |
| `Duplicate class ... found in modules` | 两个依赖带了同一个类的不同版本 | `./gradlew :app:dependencies` 找出来，用 `exclude` 排掉旧的 |
| `Manifest merger failed` | 两个库声明了冲突的 `android:theme` / `uses-sdk` | 按提示加 `tools:replace`，或统一到 app 的 Manifest |
| `AAPT: error: resource ... not found` | 资源名拼错 / 引用了未生成的资源 | 检查 `res/` 下是否真有该文件；`@string/x` 对应 `values/strings.xml` 的 `name="x"` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名与已装版本不同 | 卸载重装，或换回原密钥 |
| `INSTALL_FAILED_VERSION_DOWNGRADE` | versionCode 比已装的小 | 递进 versionCode |
