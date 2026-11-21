package com.azx8788.opencode.mini

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.TypedValue
import android.view.WindowManager
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ScrollView

/**
 * A forced, top-most Android overlay for every command that is not admitted
 * directly by the checked read-only grammar or advanced-mode policy.
 *
 * Fail-closed: no overlay permission or creation failure resolves to deny.
 * Confirmation delay and timeout come from bounded user settings.
 */
internal object ShizukuSafetyOverlay {
    private var showing = false
    private var activeId: String? = null
    private var dismiss: (() -> Unit)? = null

    fun cancel(operationId: String) {
        Handler(Looper.getMainLooper()).post {
            if (activeId == operationId) dismiss?.invoke()
        }
    }

    fun confirm(
        context: Context,
        command: String,
        decision: ShizukuCommandPolicy.Decision,
        allowDelaySeconds: Int,
        timeoutSeconds: Int,
        operationId: String = "settings",
        requestSource: String = "settings_test",
        complete: (ShizukuConfirmationOutcome) -> Unit,
    ) {
        // Always hop to main: WindowManager calls must be on the main thread.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Handler(Looper.getMainLooper()).post {
                show(context, command, decision, allowDelaySeconds, timeoutSeconds, operationId, requestSource, complete)
            }
        } else {
            show(context, command, decision, allowDelaySeconds, timeoutSeconds, operationId, requestSource, complete)
        }
    }

    private fun show(
        context: Context,
        command: String,
        decision: ShizukuCommandPolicy.Decision,
        allowDelaySeconds: Int,
        timeoutSeconds: Int,
        operationId: String,
        requestSource: String,
        complete: (ShizukuConfirmationOutcome) -> Unit,
    ) {
        if (showing) { complete(ShizukuConfirmationOutcome.UNAVAILABLE); return }
        if (!Settings.canDrawOverlays(context)) { complete(ShizukuConfirmationOutcome.PERMISSION_MISSING); return }
        if (allowDelaySeconds !in 0..60 || timeoutSeconds !in 10..120 || timeoutSeconds <= allowDelaySeconds) {
            complete(ShizukuConfirmationOutcome.UNAVAILABLE)
            return
        }

        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val main = Handler(Looper.getMainLooper())
        val chinese = context.resources.configuration.locales[0].language == "zh"

        val (bgColor, accentColor, textColor) = when (decision.risk) {
            ShizukuCommandPolicy.Risk.GREEN ->
                Triple(Color.rgb(18, 102, 52), Color.rgb(40, 160, 90), Color.WHITE)
            ShizukuCommandPolicy.Risk.BLUE ->
                Triple(Color.rgb(20, 70, 150), Color.rgb(50, 110, 200), Color.WHITE)
            ShizukuCommandPolicy.Risk.YELLOW ->
                Triple(Color.rgb(180, 130, 20), Color.rgb(255, 200, 60), Color.WHITE)
            ShizukuCommandPolicy.Risk.RED ->
                Triple(Color.rgb(150, 25, 35), Color.rgb(220, 60, 60), Color.WHITE)
        }

        val kindLabel = when (decision.kind) {
            "read_only" -> if (chinese) "只读 / 读取信息" else "Read-only / information"
            "sensitive_read" -> if (chinese) "读取敏感数据" else "Read sensitive data"
            "write_or_configuration" -> if (chinese) "写入 / 配置变更" else "Write / configuration"
            "low_impact" -> if (chinese) "低影响命令" else "Low-impact command"
            "delete_stop_or_remove" -> if (chinese) "删除 / 停用 / 卸载" else "Delete / stop / remove"
            "privilege_escalation_or_system" -> if (chinese) "提权 / 系统变更" else "Privilege / system change"
            "catastrophic_destructive_or_privilege" -> if (chinese) "极危险：破坏性 / 提权 / 关机" else "Catastrophic: destructive / privilege / shutdown"
            else -> if (chinese) "未识别指令" else "Unrecognized command"
        }

        val riskLabel = when (decision.risk) {
            ShizukuCommandPolicy.Risk.GREEN -> if (chinese) "低风险" else "Low"
            ShizukuCommandPolicy.Risk.BLUE -> if (chinese) "未知风险" else "Unknown"
            ShizukuCommandPolicy.Risk.YELLOW -> if (chinese) "中风险" else "Medium"
            ShizukuCommandPolicy.Risk.RED -> if (chinese) "高风险" else "High"
        }

        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 28, 32, 28)
            background = GradientDrawable().apply {
                cornerRadius = 28f
                setColor(bgColor)
                setStroke(3, accentColor)
            }
        }

        val title = TextView(context).apply {
            setTextColor(textColor)
            setShadowLayer(8f, 0f, 0f, Color.argb(180, 0, 0, 0))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            text = if (requestSource == "opencode_tool") {
                if (chinese) "⚠ 警告：Agent 请求执行 Android 指令" else "⚠ Warning: Agent requests Android command"
            } else {
                if (chinese) "⚠ 警告：设置页请求测试 Android 指令" else "⚠ Warning: Settings requests Android test command"
            }
        }

        val meta = TextView(context).apply {
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            text = if (chinese)
                "类型：$kindLabel\n风险等级：$riskLabel\n超时：${timeoutSeconds} 秒后自动拒绝"
            else
                "Type: $kindLabel\nRisk: $riskLabel\nTimeout: auto-deny in ${timeoutSeconds}s"
        }

        val cmdBox = TextView(context).apply {
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(20, 16, 20, 16)
            background = GradientDrawable().apply {
                cornerRadius = 16f
                setColor(Color.argb(60, 0, 0, 0))
            }
            text = command
            setTextIsSelectable(true)
        }

        val scrollBody = ScrollView(context).apply {
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(title)
                addView(meta)
                addView(cmdBox)
                setPadding(0, 0, 0, 12)
            })
        }

        fun dp(v: Int) = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), context.resources.displayMetrics
        ).toInt()

        val allowBtn = Button(context).apply {
            text = if (chinese) "仅允许本次执行" else "Allow once"
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = 14f
                setColor(accentColor)
            }
            filterTouchesWhenObscured = true
            isEnabled = false
            alpha = 0.4f
        }

        val denyBtn = Button(context).apply {
            text = if (chinese) "拒绝 / 关闭" else "Deny / close"
            setTextColor(textColor)
            background = GradientDrawable().apply {
                cornerRadius = 14f
                setColor(Color.argb(80, 0, 0, 0))
            }
            filterTouchesWhenObscured = true
        }

        val buttons = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            weightSum = 2f
            addView(denyBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8)
            })
            addView(allowBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }

        panel.addView(scrollBody, LinearLayout.LayoutParams(-1, 0, 1f))
        panel.addView(buttons, LinearLayout.LayoutParams(-1, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })

        val countdownText = TextView(context).apply {
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
        }
        panel.addView(countdownText, LinearLayout.LayoutParams(-1, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(6)
        })

        val delayMs = allowDelaySeconds * 1000L
        val startedAt = SystemClock.elapsedRealtime()
        val timeoutMs = timeoutSeconds * 1000L
        val confirmation = ShizukuConfirmation(delayMs, timeoutMs) { outcome ->
            main.removeCallbacksAndMessages(null)
            runCatching { wm.removeView(panel) }
            showing = false
            activeId = null
            dismiss = null
            complete(outcome)
        }

        // The configured allow delay elapses before the button is tappable;
        // the independent timeout always resolves to deny.
        denyBtn.setOnClickListener {
            confirmation.choose(false, SystemClock.elapsedRealtime() - startedAt, Settings.canDrawOverlays(context))
        }
        allowBtn.setOnClickListener {
            confirmation.choose(true, SystemClock.elapsedRealtime() - startedAt, Settings.canDrawOverlays(context))
        }
        val countdown = object : Runnable {
            override fun run() {
                val elapsed = SystemClock.elapsedRealtime() - startedAt
                confirmation.tick(elapsed, Settings.canDrawOverlays(context))
                if (confirmation.isFinished) return
                val remaining = (delayMs - elapsed).coerceAtLeast(0)
                val secondsLeft = (timeoutMs - elapsed + 999) / 1000
                if (remaining > 0) {
                    countdownText.text = if (chinese)
                        "允许按钮 ${remaining / 1000 + 1} 秒后可用" else "Allow in ${remaining / 1000 + 1}s"
                } else {
                    allowBtn.isEnabled = true
                    allowBtn.alpha = 1f
                    countdownText.text = if (chinese)
                        "请仔细确认后选择（$secondsLeft 秒后拒绝）" else "Review and choose (deny in ${secondsLeft}s)"
                }
                main.postDelayed(this, 200)
            }
        }

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        val params = WindowManager.LayoutParams(
            (context.resources.displayMetrics.widthPixels * 0.94).toInt(),
            (context.resources.displayMetrics.heightPixels * 0.62).toInt(),
            layoutType,
            WindowManager.LayoutParams.FLAG_SECURE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.CENTER
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
        }

        try {
            showing = true
            activeId = operationId
            dismiss = { confirmation.finish(ShizukuConfirmationOutcome.CANCELLED) }
            wm.addView(panel, params)
            main.post(countdown)
            main.postDelayed({ confirmation.tick(SystemClock.elapsedRealtime() - startedAt, Settings.canDrawOverlays(context)) }, timeoutMs)
        } catch (_: Exception) {
            confirmation.finish(ShizukuConfirmationOutcome.UNAVAILABLE)
        }
    }
}
