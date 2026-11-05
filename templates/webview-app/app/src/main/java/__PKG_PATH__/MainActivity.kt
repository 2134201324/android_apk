package __PKG__

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.IOException

/**
 * WebView 套壳宿主。
 *
 * 关键设计（照抄即可，不要改回 file://）：
 * 1. 页面用 `https://appassets.androidplatform.net/assets/index.html` 加载，
 *    由 [shouldInterceptRequest] 从 APK 的 assets 里直接读出字节流返回。
 *    为什么不用 `file:///android_asset/`：file 协议下 origin 是 null，
 *    fetch/XHR 会被 CORS 拦、localStorage 分区不稳定、Service Worker 直接不可用。
 *    用 https 假域名后，页面就是一个正常的安全上下文，前端代码零改动。
 * 2. 外链一律交给系统浏览器，不在 WebView 里开 —— 否则用户点进一个没有返回键的页面就困住了。
 * 3. 加载失败要给可读页面，不能留白屏。白屏是套壳应用最差的失败形态。
 */
class MainActivity : Activity() {

    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        webView = WebView(this)
        webView.setBackgroundColor(Color.parseColor("#0B0F14"))
        setContentView(webView)

        // 只在 debug 包开远程调试（chrome://inspect）。release 包开着等于给攻击者留后门。
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)

        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true          // localStorage / sessionStorage
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false  // 游戏音效不需要用户先点一下
            cacheMode = WebSettings.LOAD_DEFAULT
            allowFileAccess = false           // 关掉才能杜绝 file:// 越权读私有文件
            allowContentAccess = false
            // 不跟随系统字体缩放：否则用户把字体调大，页面布局会整体错位。
            textZoom = 100
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            }
        }

        webView.webViewClient = object : WebViewClient() {

            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest
            ): WebResourceResponse? {
                val url = request.url
                if (url.host != ASSET_HOST) return null

                val path = url.path?.removePrefix("/assets/")?.takeIf { it.isNotBlank() }
                    ?: return null

                return try {
                    WebResourceResponse(
                        mimeOf(path),
                        null,
                        200,
                        "OK",
                        mapOf("Cache-Control" to "no-cache"),
                        assets.open(path)
                    )
                } catch (_: IOException) {
                    null   // 让 WebView 走自己的 404，不要抛异常把整个页面拖死
                }
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                val url: Uri = request.url
                if (url.host == ASSET_HOST) return false

                // 站外链接交给系统浏览器；没有可处理的应用时静默吞掉，不要崩。
                return try {
                    startActivity(Intent(Intent.ACTION_VIEW, url))
                    true
                } catch (_: Exception) {
                    true
                }
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: android.webkit.WebResourceError
            ) {
                // 只处理主文档的错误；子资源（图片/字体）失败不该整页替换。
                if (!request.isForMainFrame) return
                view.loadDataWithBaseURL(
                    null,
                    errorPage(error.description?.toString() ?: "未知错误"),
                    "text/html",
                    "utf-8",
                    null
                )
            }
        }

        webView.loadUrl(START_URL)
    }

    /** 系统返回键优先交给页面（单页应用的路由、弹窗都靠它），实在退不动才退出应用。 */
    @Deprecated("targetSdk 34 仍可用；升到 35+ 改用 OnBackPressedDispatcher")
    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    override fun onPause() {
        super.onPause()
        webView.onPause()
        webView.pauseTimers()   // 切后台停掉 JS 定时器，别在后台空转耗电
    }

    override fun onResume() {
        super.onResume()
        webView.resumeTimers()
        webView.onResume()
    }

    override fun onDestroy() {
        // 必须销毁，否则 WebView 持有的 Activity 引用会泄漏，
        // 反复进出应用后表现为「越用越卡，最后 OOM」。
        webView.loadUrl("about:blank")
        webView.stopLoading()
        webView.webViewClient = WebViewClient()
        webView.destroy()
        super.onDestroy()
    }

    private fun errorPage(detail: String): String = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{height:100%;margin:0;background:#0B0F14;color:#E5E7EB;
                    font:15px/1.6 -apple-system,system-ui,sans-serif;
                    display:flex;align-items:center;justify-content:center}
          .box{max-width:320px;padding:24px;text-align:center}
          h1{font-size:17px;font-weight:600;margin:0 0 8px}
          p{color:#94A3B8;margin:0 0 4px}
          code{color:#64748B;font-size:12px;word-break:break-all}
        </style>
        <div class="box">
          <h1>页面没能打开</h1>
          <p>应用内置页面读取失败，请重装或反馈。</p>
          <code>$detail</code>
        </div>
    """.trimIndent()

    companion object {
        /**
         * 假域名。不需要真实解析 —— 请求在 shouldInterceptRequest 就被截住了。
         * 用 https 是为了拿到安全上下文（CORS / Storage / Service Worker 正常）。
         */
        private const val ASSET_HOST = "appassets.androidplatform.net"
        private const val START_URL = "https://$ASSET_HOST/assets/index.html"

        /** 只映射实际会用到的类型；漏了会让浏览器按 text/plain 处理，JS 直接不执行。 */
        private fun mimeOf(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
            "html", "htm" -> "text/html"
            "js", "mjs" -> "application/javascript"
            "css" -> "text/css"
            "json", "map" -> "application/json"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "ico" -> "image/x-icon"
            "woff" -> "font/woff"
            "woff2" -> "font/woff2"
            "ttf" -> "font/ttf"
            "mp3" -> "audio/mpeg"
            "ogg" -> "audio/ogg"
            "wav" -> "audio/wav"
            "mp4" -> "video/mp4"
            "wasm" -> "application/wasm"
            "txt" -> "text/plain"
            else -> "application/octet-stream"
        }
    }
}
