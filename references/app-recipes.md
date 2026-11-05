# 应用配方：六类软件的骨架

每个配方都是「能编译、能跑」的最小实现，直接粘进 `MainActivity.kt` 或其旁边的新文件即可。  
依赖按需加进 `app/build.gradle.kts`，加完先跑一次 `./gradlew assembleDebug` 确认能解析。

---

## 1. 多页面应用（不引 Navigation 库）

页面少于 6 个时，`when` + `rememberSaveable` 比 Navigation 组件更省事，也更容易在进程重建后恢复。

```kotlin
enum class Screen { Home, Detail, Settings }

@Composable
fun App() {
    var screen by rememberSaveable { mutableStateOf(Screen.Home) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }

    // 返回键：非首页时回首页，而不是直接退出应用
    BackHandler(enabled = screen != Screen.Home) { screen = Screen.Home }

    when (screen) {
        Screen.Home -> HomeScreen(
            onOpen = { id -> selectedId = id; screen = Screen.Detail },
            onSettings = { screen = Screen.Settings }
        )
        Screen.Detail -> DetailScreen(selectedId, onBack = { screen = Screen.Home })
        Screen.Settings -> SettingsScreen(onBack = { screen = Screen.Home })
    }
}
```

- `rememberSaveable` 存的是可序列化的简单类型；复杂对象要自定义 `Saver`。
- `BackHandler` 来自 `androidx.activity:activity-compose`，记得加依赖。
- 页面超过 8 个、需要深链接时再上 `navigation-compose`，否则是过度设计。

---

## 2. 列表 + 详情（大数据量不卡）

```kotlin
@Composable
fun ItemList(items: List<Item>, onClick: (Item) -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items(items, key = { it.id }) { item ->   // key 必须稳定，否则滚动会跳
            Card(onClick = { onClick(item) }) {
                Column(Modifier.padding(14.dp)) {
                    Text(item.title, style = MaterialTheme.typography.titleMedium)
                    Text(item.subtitle, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
```

**三条性能红线**：
1. `key` 用稳定 id，不要用下标 —— 用下标时插入/删除会导致整屏重组。
2. 不要在 `items {}` 里做耗时计算（排序、过滤），提前在 ViewModel 算好。
3. 图片必须异步加载 + 缓存，同步 `BitmapFactory.decodeFile` 在长列表里必卡。

---

## 3. 接大模型（流式输出，OpenAI 兼容）

依赖：`implementation("com.squareup.okhttp3:okhttp:4.12.0")`

```kotlin
class ChatClient(private val baseUrl: String, private val apiKey: String, private val model: String) {

    /** 逐段回调增量文本；调用方在 IO 协程里收集。 */
    fun stream(messages: List<Msg>, onDelta: (String) -> Unit, onDone: () -> Unit, onError: (Throwable) -> Unit) {
        val body = buildJsonObject {
            put("model", model)
            put("stream", true)
            putJsonArray("messages") {
                messages.forEach { addJsonObject { put("role", it.role); put("content", it.content) } }
            }
        }.toString()

        val req = Request.Builder()
            .url("${baseUrl.trimEnd('/')}/chat/completions")
            .header("Authorization", "Bearer $apiKey")
            .header("Content-Type", "application/json")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        // 关键：流式响应不能设整体 readTimeout，否则长回答必断
        val client = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = onError(e)

            override fun onResponse(call: Call, resp: Response) {
                resp.use {
                    if (!resp.isSuccessful) {
                        onError(IOException("HTTP ${resp.code}: ${resp.body?.string()?.take(300)}"))
                        return
                    }
                    val source = resp.body!!.source()
                    while (!source.exhausted()) {
                        val line = source.readUtf8Line() ?: break
                        if (!line.startsWith("data:")) continue
                        val data = line.removePrefix("data:").trim()
                        if (data == "[DONE]") break
                        // 解析 choices[0].delta.content，空 delta（role 帧）直接跳过
                        runCatching {
                            val obj = Json.parseToJsonElement(data).jsonObject
                            obj["choices"]?.jsonArray?.firstOrNull()?.jsonObject
                                ?.get("delta")?.jsonObject?.get("content")
                                ?.jsonPrimitive?.contentOrNull
                        }.getOrNull()?.let(onDelta)
                    }
                    onDone()
                }
            }
        })
    }
}
```

**必须处理的四件事**（少一件就会在真实用户手里出问题）：

| 问题 | 现象 | 处理 |
|---|---|---|
| SSE 分帧 | 一个 JSON 被拆成两行、或两帧粘在一行 | 按行读、只认 `data:` 前缀；不要按字节块解析 |
| 空 delta | 第一帧只有 `{"role":"assistant"}` | `content` 为 null 时跳过，不要当成空字符串拼进去 |
| 历史里的图片 | 多模态消息的 `content` 是数组，纯文本网关直接 400 | 发请求前把历史里的数组压平成文字占位，只保留本轮为富文本 |
| 用户中断 | 页面退出后回调仍往已销毁的 State 写 | 用 `viewModelScope` 启的协程 + `call.cancel()`；Compose 侧判断 `isActive` |

**排版**：流式渲染 Markdown 不要每帧全量重排。按 100–150ms 节流刷新，或者只在段落边界（`\n\n`）更新一次。

---

## 4. 本地持久化：先别上数据库

| 数据量 | 方案 | 理由 |
|---|---|---|
| 配置、开关、上次选中的 tab | `DataStore Preferences` | 异步、类型安全、不会像 SharedPreferences 那样卡主线程 |
| 几十条到几千条记录 | 一个 JSON 文件 + 内存缓存 | 零依赖，读写直观，出问题能直接看文件 |
| 上万条、要查询/排序/分页 | Room | 只有这时才值得引入 KSP + 注解处理器 |

JSON 文件方案（推荐默认）：

```kotlin
class JsonStore(private val file: File, private val json: Json = Json { ignoreUnknownKeys = true }) {
    private val lock = Any()

    fun <T> read(type: KSerializer<T>, fallback: T): T = synchronized(lock) {
        runCatching { json.decodeFromString(type, file.readText()) }.getOrDefault(fallback)
    }

    fun <T> write(type: KSerializer<T>, value: T) = synchronized(lock) {
        file.parentFile?.mkdirs()
        // 先写临时文件再 rename：写到一半被杀进程也不会留下半个损坏的 JSON
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(json.encodeToString(type, value))
        tmp.renameTo(file)
    }
}
```

**原子写**那两行是重点。直接 `file.writeText()` 在写入过程中被系统杀掉，下次启动就是一个解析失败的半截文件 —— 表现为"应用每次冷启动都丢数据"。

---

## 5. 选图 + 显示（不 OOM、不转向）

```kotlin
// 选择
val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
    if (uri != null) viewModel.attach(uri)
}

// 持久化权限：只在需要跨重启访问时才要；会话内用完即弃不需要
```

```kotlin
// 解码（降采样 + EXIF 旋转）
fun decodeSampled(context: Context, uri: Uri, reqSize: Int): Bitmap? {
    val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
    var sample = 1
    while (opts.outWidth / sample > reqSize * 2) sample *= 2

    val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
    val bmp = context.contentResolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, decodeOpts)
    } ?: return null

    val degrees = context.contentResolver.openInputStream(uri)?.use {
        when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
    } ?: 0f

    if (degrees == 0f) return bmp
    val m = Matrix().apply { postRotate(degrees) }
    return Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
}
```

**不要把 base64 存进会话文件**。会话里只存 URI 字符串，发送时才读流编码。否则聊 20 轮，会话文件几百 MB，启动直接卡死。

---

## 6. 后台长任务 + 通知进度

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service android:name=".WorkService"
         android:foregroundServiceType="dataSync"
         android:exported="false" />
```

```kotlin
class WorkService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("正在处理")
            .setSmallIcon(R.drawable.ic_notification)   // 必须是纯白单色，彩色图标会变成白方块
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, n)
        }

        // 任务放应用级 CoroutineScope，不要用 service 自己的 scope：
        // 服务被系统重启时任务不该跟着从头再来
        AppScope.launch {
            runTask { progress -> updateNotification(progress) }
            stopSelf()
        }
        return START_NOT_STICKY
    }
}
```

**通知频道**要在 `Application.onCreate` 里建，否则 Android 8+ 通知直接不显示（且不报错）：

```kotlin
NotificationManagerCompat.from(this).createNotificationChannel(
    NotificationChannel(CHANNEL_ID, "处理进度", NotificationManager.IMPORTANCE_LOW)
)
```

---

## 7. WebView 进阶：JS 与原生互调

```kotlin
// 原生 → JS
webView.evaluateJavascript("window.onNativeEvent(${JSONObject.quote(payload)})", null)

// JS → 原生
class Bridge(private val onSave: (String) -> Unit) {
    @JavascriptInterface
    fun save(text: String) { onSave(text) }      // 注意：这个回调在 WebView 的线程，不是主线程
}
webView.addJavascriptInterface(Bridge { ... }, "Android")
```

```js
// 页面侧
window.Android?.save(JSON.stringify(state));
```

**三条安全规则**：
1. `addJavascriptInterface` 只暴露必要方法，且校验入参（等于给网页开了原生后门）。
2. 只在加载**自己打包的页面**时注入，不要对任意 URL 注入。
3. 传对象用 JSON 字符串，不要试图直接传 Kotlin 对象。

---

## 8. 主题与深色模式

```kotlin
@Composable
fun AppTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) darkColorScheme(
        primary = Color(0xFF7AA2FF),
        background = Color(0xFF0B0F14),
        surface = Color(0xFF151B23),
    ) else lightColorScheme(
        primary = Color(0xFF2F5FD0),
        background = Color(0xFFF7F8FA),
    )
    MaterialTheme(colorScheme = colors, content = content)
}
```

- **只在一处套 `MaterialTheme`**。页面内部再套一层，深色切换时会出现"一半深一半浅"。
- 自定义颜色不要写死 `Color(0xFF...)` 在组件里，统一从 `MaterialTheme.colorScheme` 取，否则深色模式必翻车。
- 状态栏交给 `enableEdgeToEdge()`，不要在 theme XML 里再设颜色。

---

## 9. 运行时权限：一次申请完，别一个个弹

```kotlin
private val needed = buildList {
    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    if (needCamera) add(Manifest.permission.CAMERA)
}

val launcher = rememberLauncherForActivityResult(RequestMultiplePermissions()) { result ->
    val denied = result.filterValues { !it }.keys
    if (denied.isNotEmpty()) showReasonDialog(denied)   // 说明用途 + 引导去设置
}

LaunchedEffect(Unit) {
    val missing = needed.filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }
    if (missing.isNotEmpty()) launcher.launch(missing.toTypedArray())
}
```

**被永久拒绝后 `launch()` 不再弹窗**（直接回调 false）。此时唯一出路是引导用户去系统设置，用 `Settings.ACTION_APPLICATION_DETAILS_SETTINGS` 跳转。不做这一步，用户会觉得"点了没反应"。

---

## 10. 把现成的 HTML 游戏/工具打成 APK

这是最快的交付路径，全程不需要改一行 JS：

```bash
# 1. 建工程
bash scripts/init-project.sh --name "我的游戏" --pkg com.acme.game --template webview --dir /workspace/game

# 2. 把网页整个目录覆盖进 assets（保留 index.html 在根）
rm -rf /workspace/game/app/src/main/assets/*
cp -r /path/to/your/webapp/. /workspace/game/app/src/main/assets/

# 3. 出包
bash scripts/build.sh --project /workspace/game --version-name 1.0.0 --version-code 1
```

**移植检查清单**：
- [ ] 所有 `<script src>` / `<link href>` 是相对路径，没有 `https://cdn...`
- [ ] 没有 `fetch('/api/...')` 依赖本地服务器；有的话改成相对路径并确认资源已打包
- [ ] 触摸事件用的是 `pointerdown` 或 `touchstart`，不是 `mousedown`
- [ ] 画布按 `devicePixelRatio` 缩放，否则高分屏上字和线发虚
- [ ] 用 `env(safe-area-inset-*)` 避让刘海和手势条
- [ ] 音效在首次用户交互后才 `AudioContext.resume()`（浏览器策略，WebView 同样适用）

**如果页面必须联网**：Manifest 里保留 `INTERNET` 权限；纯离线就删掉，安装时少一项授权提示。
