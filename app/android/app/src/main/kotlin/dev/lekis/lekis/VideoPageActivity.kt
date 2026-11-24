package dev.lekis.lekis

import android.annotation.SuppressLint
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.view.Gravity
import android.view.View
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.content.IntentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.ByteArrayInputStream

class VideoPageActivity : ComponentActivity() {
    private lateinit var page: VideoPage
    private lateinit var root: FrameLayout
    private lateinit var panel: LinearLayout
    private lateinit var content: FrameLayout
    private var player: WebView? = null
    private var customView: View? = null
    private var customCallback: WebChromeClient.CustomViewCallback? = null
    private var reply: ResultReceiver? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { showError("timeout") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        reply = IntentCompat.getParcelableExtra(intent, "reply", ResultReceiver::class.java)
        val requested = VideoPage.fromArguments(
            mapOf(
                "url" to intent.getStringExtra("url"),
                "title" to intent.getStringExtra("title"),
            ),
        )
        if (requested == null) {
            completeOpen("invalid_args")
            finish()
            return
        }
        page = requested
        page.title?.let { title = it }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        ViewCompat.setOnApplyWindowInsetsListener(panel) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        panel.addView(Button(this).apply {
            setText(R.string.video_close)
            setOnClickListener { finish() }
        }, LinearLayout.LayoutParams(-2, -2))
        content = FrameLayout(this)
        panel.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(panel)
        setContentView(root)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (customView != null) leaveFullscreen() else finish()
            }
        })
        loadPlayer()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun loadPlayer() {
        content.removeAllViews()
        val web = try {
            WebView(this)
        } catch (_: RuntimeException) {
            showError()
            return
        }
        player = web
        web.setDownloadListener { _, _, _, _, _ -> }
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true)
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                !request.isForMainFrame || !page.allowsNavigation(request.url.toString())

            override fun onPageFinished(view: WebView, url: String) {
                if (view === player && !isFinishing && page.allowsNavigation(url)) completeOpen()
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.isForMainFrame &&
                    (request.method != "GET" || !page.allowsNavigation(request.url.toString()))) {
                    return WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(),
                        ByteArrayInputStream(byteArrayOf()))
                }
                return null
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame && view === player) showError()
            }

            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, error: WebResourceResponse) {
                if (request.isForMainFrame && view === player) showError()
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                if (view === player) showError()
                return true
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                if (customView != null || player !== web || isFinishing) {
                    callback.onCustomViewHidden()
                    return
                }
                customView = view
                customCallback = callback
                panel.visibility = View.GONE
                root.addView(view)
                WindowCompat.getInsetsController(window, root).apply {
                    systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    hide(WindowInsetsCompat.Type.systemBars())
                }
            }

            override fun onHideCustomView() = leaveFullscreen()
        }
        content.addView(web)
        handler.postDelayed(timeout, 30_000)
        web.loadUrl(page.url)
    }

    private fun leaveFullscreen() {
        val view = customView ?: return
        customView = null
        root.removeView(view)
        panel.visibility = View.VISIBLE
        WindowCompat.getInsetsController(window, root).show(WindowInsetsCompat.Type.systemBars())
        val callback = customCallback
        customCallback = null
        callback?.onCustomViewHidden()
    }

    private fun releasePlayer() {
        val web = player ?: return
        player = null
        leaveFullscreen()
        content.removeView(web)
        web.webChromeClient = null
        web.destroy()
    }

    private fun completeOpen(error: String? = null) {
        handler.removeCallbacks(timeout)
        reply?.send(if (error == null) RESULT_OK else RESULT_CANCELED, Bundle().apply { putString("code", error) })
        reply = null
        intent.removeExtra("reply")
    }

    private fun showError(code: String = "load_failed") {
        val opening = reply != null
        completeOpen(code)
        releasePlayer()
        if (opening) {
            finish()
            return
        }
        content.removeAllViews()
        val message = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(TextView(context).apply { setText(R.string.video_load_error) })
            addView(Button(context).apply {
                setText(R.string.video_retry)
                setOnClickListener { loadPlayer() }
            })
        }
        content.addView(message)
    }

    override fun onPause() {
        player?.let { web ->
            web.evaluateJavascript("document.querySelectorAll('video,audio').forEach(e=>e.pause())", null)
            web.onPause()
        }
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        player?.onResume()
    }

    override fun onDestroy() {
        if (isFinishing) completeOpen("closed")
        handler.removeCallbacks(timeout)
        releasePlayer()
        super.onDestroy()
    }
}
