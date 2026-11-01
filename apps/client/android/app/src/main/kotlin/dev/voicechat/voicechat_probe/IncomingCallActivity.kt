package dev.voicechat.voicechat_probe

import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/** Resolve the short-lived call before opening Flutter in call-only mode. */
class IncomingCallActivity : Activity() {
    companion object {
        private var current = WeakReference<IncomingCallActivity>(null)
        fun dismissSession(session: String) {
            Handler(Looper.getMainLooper()).post {
                current.get()?.let { if (it.intent.getStringExtra("pushSession") == session) it.finish() }
            }
        }
        fun dismiss(notice: String) {
            Handler(Looper.getMainLooper()).post {
                current.get()?.let { if (it.intent.getStringExtra("pushNotice") == notice) it.finish() }
            }
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private lateinit var title: TextView
    private lateinit var answer: Button
    private var binding = ""
    private var notice = ""

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        binding = intent.getStringExtra("pushBinding") ?: ""
        notice = intent.getStringExtra("pushNotice") ?: ""
        val remaining = (intent.getLongExtra("pushExpires", 0) * 1000 - System.currentTimeMillis()).coerceAtMost(45000L)
        if (binding != PushNotifications.binding(this) || notice.isEmpty() || remaining <= 0) { finish(); return }
        current = WeakReference(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        title = TextView(this).apply { text = "VoiceChat\nВходящий звонок"; textSize = 26f; gravity = Gravity.CENTER }
        answer = Button(this).apply { text = "Ответить"; isEnabled = false; setOnClickListener { answerCall() } }
        val decline = Button(this).apply {
            text = "Отклонить"
            setOnClickListener {
                getSystemService(NotificationManager::class.java).cancel(intent.getStringExtra("pushTag"), 0)
                PushWork.enqueue(this@IncomingCallActivity, "decline", notice, binding)
                finish()
            }
        }
        for (view in listOf(title, answer, decline)) layout.addView(view,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        setContentView(layout)
        main.postDelayed({ finish() }, remaining)
        Thread {
            val data = try { PushNotifications.resolve(this, binding, notice) }
                catch (_: Exception) { null }
            main.post {
                if (isFinishing || isDestroyed) return@post
                if (data?.optString("kind") != "call" || binding != PushNotifications.binding(this)) { finish(); return@post }
                if (data.optBoolean("video")) {
                    title.text = "VoiceChat\nВходящий видеозвонок"
                    answer.text = "Ответить с камерой"
                }
                answer.isEnabled = true
                openCall(intent.getStringExtra("pushAction") == "answer")
            }
        }.start()
    }

    private fun answerCall() { openCall(true) }

    override fun onNewIntent(incoming: Intent) {
        super.onNewIntent(incoming)
        if (incoming.getStringExtra("pushNotice") != notice) {
            finish()
            startActivity(Intent(incoming).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        setIntent(incoming)
        if (incoming.getStringExtra("pushAction") == "answer" && answer.isEnabled) answerCall()
    }

    private fun openCall(answerNow: Boolean) {
        if (isFinishing || binding != PushNotifications.binding(this) ||
            intent.getLongExtra("pushExpires", 0) * 1000 <= System.currentTimeMillis()) return
        if (answerNow) getSystemService(NotificationManager::class.java).cancel(intent.getStringExtra("pushTag"), 0)
        startActivity(Intent(this, MainActivity::class.java).putExtras(intent)
            .putExtra("callScreen", true)
            .putExtra("pushAction", if (answerNow) "answer" else "show").addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        finish()
    }

    override fun onDestroy() {
        if (current.get() == this) current.clear()
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
