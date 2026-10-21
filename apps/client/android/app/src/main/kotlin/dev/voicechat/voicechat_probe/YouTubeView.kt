package dev.voicechat.voicechat_probe

import android.content.Context
import android.view.View
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.graphics.Bitmap
import android.graphics.Color
import android.webkit.WebResourceError
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebSettings
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class YouTubeFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val id = args as? String ?: ""
        require(Regex("^[A-Za-z0-9_-]{11}$").matches(id))
        val web = WebView(context)
        val container = FrameLayout(context)
        container.setBackgroundColor(Color.BLACK)
        val progress = ProgressBar(context)
        var disposed = false
        val spinnerSize = (48 * context.resources.displayMetrics.density).toInt()
        container.addView(web, FrameLayout.LayoutParams(-1, -1))
        container.addView(progress, FrameLayout.LayoutParams(spinnerSize, spinnerSize, Gravity.CENTER))
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
        web.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                if (disposed) return
                web.visibility = View.INVISIBLE
                progress.visibility = View.VISIBLE
            }
            override fun onPageFinished(view: WebView, url: String?) {
                if (disposed) return
                progress.visibility = View.GONE
                web.visibility = View.VISIBLE
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (disposed) return
                if (request.isForMainFrame) {
                    progress.visibility = View.GONE
                    web.visibility = View.VISIBLE
                }
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                return request.isForMainFrame && !(uri.scheme == "https" &&
                    uri.host in listOf("www.youtube.com", "www.youtube-nocookie.com") && uri.path == "/embed/$id")
            }
        }
        web.loadUrl("https://www.youtube-nocookie.com/embed/$id?autoplay=0&playsinline=1",
            mapOf("Referer" to "https://${context.packageName}/"))
        return object : PlatformView {
            override fun getView(): View = container
            override fun dispose() {
                if (disposed) return
                disposed = true
                web.stopLoading()
                web.webViewClient = WebViewClient()
                web.loadUrl("about:blank")
                web.removeAllViews()
                container.removeAllViews()
                web.destroy()
            }
        }
    }
}
