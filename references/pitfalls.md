# 20 条真实踩坑：症状 → 根因 → 修法

这些不是"可能遇到的问题"，是**已经付过代价的问题**。按症状检索，不要从头读。

---

## 1. 应用私有目录里的二进制一执行就 `EACCES`（Permission denied）

**症状**：把 bash / ffmpeg / 自带运行时解压到 `/data/data/<包名>/files/`，`setExecutable(true)` 返回 true，但 `Runtime.exec` 报 `error=13, Permission denied`。Android 9 及以下正常。

**根因**：Android 10（API 29）起 SELinux 对 `app_data_file` 实施 W^X —— `targetSdk >= 29` 的应用被禁止 `execve` 自己数据目录里的文件。`chmod` 成功不代表能执行。

**修法**：`targetSdk = 28`。这是 Termux 官方同款做法（termux-app#1072）。Android 14 的安装底线是 targetSdk ≥ 23，28 完全能装、能跑。

**代价**：不能用 Android 10+ 的部分新行为（分区存储强制、后台启动限制更严），且上架 Google Play 会被拒。纯侧载分发无影响。

**替代路线**：APK 原生库打包（把可执行文件放进 `jniLibs/<abi>/`，安装时系统解压到 `nativeLibraryDir`，那里允许 exec），再在私有目录建符号链接农场。代价是 APK 体积翻倍、且和 dpkg 这类"必须从可写目录执行维护脚本"的工具冲突。

---

## 2. 自绘图标在真机上缩小到 1/3，缩在左上角

**症状**：Compose `Canvas` 里按 `size.width` 算坐标画图标，模拟器正常，density=3 的真机上图形只占左上角一小块。

**根因**：`DrawScope.size` 的单位是**像素**，而 `Dp.value` / `sp` 是**密度无关单位**。写了 `val scale = size.value / 24f` 就等于把像素当 dp 用，在 density=3 时算出 1/3 的缩放。

**修法**：

```kotlin
// ✗ 错
val scale = size.value / 24f
// ✓ 对：直接用像素做除法，两者同单位
val scale = size.minDimension / 24f
// 描边宽度如果来自 dp，必须换算
drawPath(path, color, style = Stroke(width = 1.5.dp.toPx()))
```

**验证**：写一个 density 参数化的单测/Robolectric 测试，分别在 1x / 2x / 3x 下断言绘制边界接近画布尺寸。只靠肉眼看模拟器一定会漏。

---

## 3. 用户选的图片，模型收到的却是另一张

**症状**：`ActivityResultContracts.GetContent()` 选图后上传，模型描述的图片和用户选的不一致；同一张图重复选，结果时好时坏。

**根因**：`GetContent` 返回的是 DocumentsUI 托管的**临时副本** URI（`content://com.android.providers.media.documents/...`）。部分 ROM 上该 URI 指向一个会被复用/覆盖的缓存文件，读取时可能拿到上一张图。

**修法**：改用 `ActivityResultContracts.PickVisualMedia()`，它返回原始媒体 URI（`content://media/picker/...`），语义就是"用户选的那张照片"。

```kotlin
val picker = rememberLauncherForActivityResult(
    ActivityResultContracts.PickVisualMedia()
) { uri -> uri?.let { onImagePicked(it) } }

picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
```

**注意**：`PickVisualMedia` 的构造函数签名在不同 `androidx.activity` 版本间变过（1.7 有参、1.9 无参）。以实际依赖版本的 `javap` 为准，不要照抄博客。

---

## 4. 新版本装不上去：`INSTALL_FAILED_UPDATE_INCOMPATIBLE`

**症状**：用户手机上已有旧版，装新版提示"应用未安装"/"签名不一致"。

**根因**：两次构建用了不同的签名密钥。最常见于"每次构建都自动生成 debug.keystore"的脚手架 —— 换台机器/换个沙盒，钥匙就变了。

**修法**：
1. 密钥必须**固化在工程里**（`signing/release.keystore`），随源码一起备份，永不重新生成。
2. 构建脚本读固定的 `keystore.properties`，不要回落到 `~/.android/debug.keystore`。
3. 交付时记录证书 SHA-256 指纹，下个版本对比一次。

**已经换了的补救**：只能让用户卸载重装（数据丢失）。所以第一次交付前就要把钥匙定下来。

---

## 5. 文件名是新版，装上去却是旧功能

**症状**：`我的应用-v1.3.0.apk` 装上后版本号显示 1.2.0，新功能没有。

**根因**：Gradle 构建失败时**不会删除上一次的产物**。脚本继续往下走，把磁盘上的旧 APK 重命名 + 重签名，得到"新名字、旧内容"的包。签名和安装都不会报错。

**修法**：签名前读产物内的 versionCode，与源码里的比对，不一致直接失败：

```bash
APK_CODE=$(aapt2 dump badging app-release-unsigned.apk | grep -oP "versionCode='\K[0-9]+")
[ "$APK_CODE" = "$SRC_CODE" ] || { echo "产物是旧的，构建没成功"; exit 1; }
```

`build.sh` 已内置这条硬校验。**不要绕过脚本手工签包。**

---

## 6. 构建日志停在 R8 然后进程消失

**症状**：`./gradlew assembleRelease` 跑十几分钟，日志最后一行是 `minifyReleaseWithR8`，然后没有 BUILD SUCCESSFUL、没有报错，进程没了。`dmesg` 里也没有 OOM 记录。

**根因**：不一定是内存不足。容器/沙盒对长跑进程有资源回收策略，R8 的长时间大内存占用容易触发。

**修法**：`-Xmx` 加到 8g/12g，**换 SerialGC**（短命大内存比 G1 抗回收），`org.gradle.parallel=false`。实测同一工程从"连续三次失败"变成"2 分半通过"。

---

## 7. `lintVitalRelease` 让 release 构建失败

**症状**：debug 能构建，release 报 `ExpiredTargetSdkVersion` / `OldTargetApi` / `MissingTranslation`。

**根因**：`lintVitalRelease` 是 release 构建的强制关卡，任何 error 级 lint 都会中断。而 `targetSdk 28` 这类**刻意的产品决策**会被判为 error。

**修法**：

```kotlin
android {
    lint {
        disable += "ExpiredTargetSdkVersion"
        disable += "OldTargetApi"
        abortOnError = false
    }
}
// 或直接不跑：android.lint.checkReleaseBuilds=false
```

质量门应该是单元测试 + `verify.sh`，不是 lint。

---

## 8. debug 正常，release 一开就闪退

**症状**：`assembleDebug` 一切正常；`assembleRelease` 装上点开就崩，日志 `ClassNotFoundException` / `NoSuchMethodException`。

**根因**：R8 把"只通过反射使用"的类裁掉了。常见于 JSON 反序列化 DTO、`Class.forName`、JNI 回调、kotlinx.serialization 的 `@Serializable`。

**修法**：模板默认 `isMinifyEnabled = false`。确实要开时，先把反射入口写进 `proguard-rules.pro`：

```proguard
-keep class com.acme.data.model.** { *; }
-keepclassmembers class * { @androidx.annotation.Keep <methods>; }
-keepattributes *Annotation*, InnerClasses, Signature
```

**验证**：release 包必须真机跑一遍主流程，不能只看"能装"。

---

## 9. Compose 项目报 `Compose Compiler plugin not found`

**症状**：Kotlin 2.0+ 项目里用 Compose，报 `This version of the Compose Compiler requires Kotlin version...` 或直接找不到 compiler。

**根因**：Kotlin 2.0 起，Compose 编译器从 `kotlinCompilerExtensionVersion` 改成了独立的 Gradle 插件。只加 `buildFeatures { compose = true }` 不够。

**修法**：三个插件都要有，且版本一致：

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")   // ← 必须有
}
```

根 `build.gradle.kts` 里 `apply false` 声明版本，版本号与 Kotlin 严格一致（如都是 2.0.21）。

---

## 10. WebView 里 `fetch` 全部失败、localStorage 读不到

**症状**：同一个 HTML 在浏览器正常，塞进 APK 后接口 404 / `Origin null is not allowed` / `localStorage is not available`。

**根因**：用 `file:///android_asset/index.html` 加载。file 协议的 origin 是 `null`，CORS 直接拒绝；Storage 在部分版本被分区隔离；Service Worker 完全不支持。

**修法**：用 https 假域名 + `shouldInterceptRequest` 从 assets 读流（模板已实现）：

```kotlin
webView.loadUrl("https://appassets.androidplatform.net/assets/index.html")
// WebViewClient 里拦截该 host，用 assets.open(path) 返回 WebResourceResponse
```

这样页面处于安全上下文，前端代码零改动。**别忘了 MIME 类型**：JS 返回 `text/plain` 会导致脚本不执行，表现为"页面出来了但按钮全都没反应"。

---

## 11. 转屏后网页游戏进度清零

**症状**：横竖屏切换，H5 游戏回到初始画面，表单内容丢失。

**根因**：`configChanges` 没声明 `orientation|screenSize`，Activity 被销毁重建，WebView 跟着重建 = 一个全新的页面。

**修法**：

```xml
<activity android:configChanges="orientation|screenSize|screenLayout|keyboardHidden|uiMode|smallestScreenSize" />
```

**进一步的**：关键状态仍应写 `localStorage`，因为进程被系统回收时 WebView 一样会重建。

---

## 12. 反复进出应用越来越卡，最后 OOM

**症状**：WebView 应用用一段时间后卡顿、崩溃 `OutOfMemoryError`。

**根因**：WebView 持有 Activity 引用，`onDestroy` 里没有销毁。

**修法**：

```kotlin
override fun onDestroy() {
    webView.loadUrl("about:blank")
    webView.stopLoading()
    webView.webViewClient = WebViewClient()
    webView.destroy()
    super.onDestroy()
}
// 另外：onPause 里 pauseTimers()，onResume 里 resumeTimers()，
// 否则切后台 JS 定时器还在跑，白耗电。
```

---

## 13. Android 14 上前台服务启动即崩

**症状**：`startForeground()` 抛 `MissingForegroundServiceTypeException` 或 `SecurityException`。

**根因**：Android 14（API 34）要求每个前台服务在 Manifest 里声明 `foregroundServiceType`，且必须申请对应权限。

**修法**：

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />

<service
    android:name=".ChatService"
    android:foregroundServiceType="specialUse"
    android:exported="false">
    <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
              android:value="用户发起的长任务" />
</service>
```

`specialUse` 是"不属于导航/媒体/定位等既有类别"时的兜底类别，上架需要说明用途；侧载无限制。

---

## 14. Android 13+ 通知不显示

**症状**：前台服务在跑，但通知栏什么都没有。

**根因**：API 33 起 `POST_NOTIFICATIONS` 是运行时权限，不申请就是默认拒绝。

**修法**：Manifest 声明 + 首次进入时请求：

```kotlin
if (Build.VERSION.SDK_INT >= 33) {
    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
}
```

没有通知的前台服务等于"看不见的服务"，系统照样随手回收 —— 加前台服务的意义就没了。

---

## 15. 摄像头拍的照片显示时横躺着

**症状**：用户拍的照片在 App 里旋转了 90°，相册里却是正的。

**根因**：JPEG 的 EXIF `Orientation` 标记。相册会读它，`BitmapFactory` 不读。

**修法**：解码后按 EXIF 旋转：

```kotlin
val exif = ExifInterface(stream)
val degrees = when (exif.getAttributeInt(TAG_ORIENTATION, ORIENTATION_NORMAL)) {
    ORIENTATION_ROTATE_90 -> 90f
    ORIENTATION_ROTATE_180 -> 180f
    ORIENTATION_ROTATE_270 -> 270f
    else -> 0f
}
// Matrix().postRotate(degrees) 后再 createBitmap
```

**顺带**：大图一定要 `inSampleSize` 降采样，直接解 4000×3000 的图在低端机上必 OOM。

---

## 16. 单元测试里一碰 `Uri.parse` 就 `RuntimeException: not mocked`

**症状**：纯 JVM 单测（`test/` 目录）里用 `android.net.Uri` 报 `Method parse not mocked`。

**根因**：`testOptions.unitTests.isReturnDefaultValues = true` 只让方法返回默认值（null/0），不会真的实现逻辑。

**修法**：把 URI 处理抽成**纯 Kotlin 字符串函数**再测：

```kotlin
// 可测
fun displayFileName(uriString: String): String =
    Uri.decode(uriString.substringAfterLast('/'))   // 自己实现 decodePercent
```

或者用 Robolectric（引入 `org.robolectric:robolectric`，测试变慢但能用真实 Android 类）。**不要为了测试把业务逻辑绑死在 Android 类型上**。

---

## 17. APK 体积莫名多出几十 MB

**症状**：代码没多少，包体 80MB+。

**根因**：
- `assets/` 里放了 zip / 数据库 / 模型文件，被二次压缩（无收益还慢）
- 依赖里带了全量多语言资源
- `debugImplementation` 的东西被打进 release（极少见）
- 没有开 `shrinkResources`

**修法**：

```kotlin
android {
    androidResources {
        noCompress += listOf("zip", "mp3", "mp4", "ogg", "webp", "so")
    }
    defaultConfig {
        resourceConfigurations += listOf("zh", "en")
    }
}
```

查体积构成：`unzip -l app.apk | sort -k1 -n -r | head -20`。

---

## 18. `zipalign` 之后签名，装上去说"解析包出错"

**症状**：`INSTALL_PARSE_FAILED_UNEXPECTED_EXCEPTION` 或安装器直接说包损坏。

**根因**：顺序错了。**必须 zipalign → 再 apksigner**。反过来的话，签名会覆盖对齐结果，v2 签名块的位置也被打乱。

**修法**：记住一条链：`assemble → zipalign -p 4 → apksigner sign → apksigner verify`。`build.sh` 已固化这个顺序。

---

## 19. 明文 HTTP 请求被拦

**症状**：`CLEARTEXT communication to ... not permitted by network security policy`。

**根因**：`targetSdk >= 28` 默认禁止明文 HTTP。

**修法**（三选一，按推荐顺序）：
1. **改用 HTTPS**（首选，没有理由用 HTTP）
2. 只对特定域名放行：`res/xml/network_security_config.xml` + `android:networkSecurityConfig`
3. 全局放行（仅调试）：`android:usesCleartextTraffic="true"` —— **不要带进 release**

---

## 20. 打包交付 ZIP 时把源码目录删空了

**症状**：`tar --exclude='*/build'` 打包后，源码里的 `com/example/build/` 目录没了。

**根因**：`--exclude` 的模式是路径匹配，`*/build` 会命中任何名为 `build` 的目录，包括 Java 包名里的 `build`。

**修法**：用**锚定到根**的精确模式：

```bash
tar -czf out.tar.gz \
    --exclude='./build' \
    --exclude='./app/build' \
    --exclude='./.gradle' \
    .
```

打包后必须验证：`tar -tzf out.tar.gz | grep 'MainActivity.kt'`，确认关键文件还在。

---

## 附：遇到本文没覆盖的问题

按这个顺序排查，比到处搜博客快：

1. **读日志第一处 error**，不是最后一行。Kotlin 编译错误的后半段全是连锁反应。
2. `./gradlew :app:dependencies` —— 依赖冲突一目了然。
3. `./gradlew assembleRelease --stacktrace --info` —— 拿到真正的异常栈。
4. `aapt2 dump badging app.apk` —— 确认包里的东西和你想的一致。
5. 缩小范围：新建一个模板工程，把可疑代码一点点搬过去，直到复现。
