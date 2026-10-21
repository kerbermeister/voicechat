package dev.voicechat.voicechat_probe

import android.content.Context
import android.view.View
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
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                return request.isForMainFrame && !(uri.scheme == "https" &&
                    uri.host in listOf("www.youtube.com", "www.youtube-nocookie.com") && uri.path == "/embed/$id")
            }
        }
        web.loadUrl("https://www.youtube-nocookie.com/embed/$id?autoplay=0&playsinline=1",
            mapOf("Referer" to "https://${context.packageName}/"))
        return object : PlatformView {
            override fun getView(): View = web
            override fun dispose() {
                web.stopLoading()
                web.loadUrl("about:blank")
                web.removeAllViews()
                web.destroy()
            }
        }
    }
}
