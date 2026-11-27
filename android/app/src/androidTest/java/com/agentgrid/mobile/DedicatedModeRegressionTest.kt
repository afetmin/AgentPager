package com.agentgrid.mobile

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * Run on an unlocked test device with system bars, camera permission granted and the
 * first-use fullscreen prompt dismissed. Use profiles with and without a camera.
 * Runner: com.agentgrid.mobile.test/com.agentgrid.mobile.DedicatedModeRegressionTest
 */
class DedicatedModeRegressionTest : Instrumentation() {
    private var activity: MainActivity? = null

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val hasCamera = targetContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
        val pairingTest = if (hasCamera) "pairingCopyWithCamera" else "pairingCopyWithoutCamera"
        val tests = listOf(
            "disabledModeIsRespectedOnColdStart" to ::disabledModeIsRespectedOnColdStart,
            "modeCanBeExitedAndReenteredWithoutRestart" to ::modeCanBeExitedAndReenteredWithoutRestart,
            pairingTest to { pairingCopyUsesComputer(hasCamera) },
        )
        val savedMode = settings().all[MODE_KEY] as? Boolean
        val pairing = targetContext.getSharedPreferences("agentgrid-pairing", Context.MODE_PRIVATE)
        val savedPairing = listOf("iv", "payload").associateWith { pairing.getString(it, null) }
        var failures = 0
        try {
            tests.forEach { (name, test) ->
                try {
                    test()
                    sendStatus(0, Bundle().apply { putString("stream", "\nPASS $name\n") })
                } catch (error: Throwable) {
                    failures++
                    sendStatus(-2, Bundle().apply {
                        putString("stream", "\nFAIL $name: ${error.stackTraceToString()}\n")
                    })
                } finally {
                    closeActivity()
                }
            }
        } finally {
            settings().edit().apply {
                if (savedMode == null) remove(MODE_KEY) else putBoolean(MODE_KEY, savedMode)
            }.commit()
            pairing.edit().apply {
                savedPairing.forEach { (key, value) ->
                    if (value == null) remove(key) else putString(key, value)
                }
            }.commit()
        }
        finish(if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("stream", "\nTests run: ${tests.size}, Failures: $failures\n")
        })
    }

    private fun disabledModeIsRespectedOnColdStart() {
        check(settings().edit().putBoolean(MODE_KEY, false).commit())
        launchActivity()
        assertWindowMode(false)
    }

    private fun modeCanBeExitedAndReenteredWithoutRestart() {
        check(settings().edit().putBoolean(MODE_KEY, false).commit())
        val original = launchActivity()
        clickLabel("打开设置")
        clickLabel("进入专用模式")
        awaitLabel("退出专用模式")
        assertWindowMode(true)

        clickLabel("退出专用模式")
        awaitLabel("进入专用模式")
        assertWindowMode(false)
        check(!settings().getBoolean(MODE_KEY, true)) { "Exit must persist disabled mode" }
        runOnMainSync { original.onWindowFocusChanged(true) }
        assertWindowMode(false)

        clickLabel("进入专用模式")
        awaitLabel("退出专用模式")
        assertWindowMode(true)
        runOnMainSync { check(!original.isFinishing && !original.isDestroyed) }
        check(settings().getBoolean(MODE_KEY, false)) { "Enter must persist enabled mode" }

        closeActivity()
        launchActivity()
        clickLabel("打开设置")
        awaitLabel("退出专用模式")
        // On relaunch check the persisted UI state and keep-awake flag; the system
        // can temporarily reveal the bars while transitioning between windows.
        runOnMainSync {
            val flags = checkNotNull(activity).window.attributes.flags
            check(flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
        }
        clickLabel("退出专用模式")
        assertWindowMode(false)
        closeActivity()
        launchActivity()
        assertWindowMode(false)
        clickLabel("打开设置")
        awaitLabel("进入专用模式")
    }

    private fun pairingCopyUsesComputer(hasCamera: Boolean) {
        check(settings().edit().putBoolean(MODE_KEY, false).commit())
        val pairing = targetContext.getSharedPreferences("agentgrid-pairing", Context.MODE_PRIVATE)
        check(pairing.edit().remove("iv").remove("payload").commit())
        launchActivity(paired = false)
        awaitLabel(if (hasCamera) "扫描电脑上的二维码" else "输入电脑端配对文本")
        awaitLabel("在电脑上打开 AgentPager Bridge → 连接", exact = false)
        awaitLabel(if (hasCamera) "无法扫码？粘贴电脑端配对文本" else "电脑端配对文本")
        awaitLabel("连接 Bridge")
    }

    private fun settings() = targetContext.getSharedPreferences("agentgrid-settings", Context.MODE_PRIVATE)

    private fun launchActivity(paired: Boolean = true): MainActivity {
        val intent = Intent(targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (paired) putExtra(MainActivity.EXTRA_PAIRING, LOOPBACK_PAIRING)
        }
        return (startActivitySync(intent) as MainActivity).also { activity = it }
    }

    private fun closeActivity() {
        val current = activity ?: return
        runOnMainSync { current.finish() }
        await("Activity did not finish") {
            var destroyed = false
            runOnMainSync { destroyed = current.isDestroyed }
            destroyed
        }
        activity = null
    }

    private fun clickLabel(label: String) {
        var node = awaitLabel(label)
        while (!node.isClickable) node = checkNotNull(node.parent) { "$label is not clickable" }
        check(node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "Could not click $label" }
    }

    private fun awaitLabel(label: String, exact: Boolean = true): AccessibilityNodeInfo {
        var result: AccessibilityNodeInfo? = null
        await("Missing UI label: $label") {
            result = uiAutomation.rootInActiveWindow?.findNode { node ->
                node.isVisibleToUser && listOfNotNull(node.text, node.contentDescription).any { text ->
                    if (exact) text.toString() == label else text.contains(label)
                }
            }
            result != null
        }
        return checkNotNull(result)
    }

    private fun AccessibilityNodeInfo.findNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (matches(this)) return this
        for (index in 0 until childCount) {
            getChild(index)?.findNode(matches)?.let { return it }
        }
        return null
    }

    @Suppress("DEPRECATION") // Before API 30 the controller uses decor view flags, not visibility insets.
    private fun assertWindowMode(enabled: Boolean) {
        await("Expected dedicated mode=$enabled (system bars and keep-screen-on)") {
            var matches = false
            runOnMainSync {
                val window = checkNotNull(activity).window
                val keepScreenOn = window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
                val barsMatch = if (Build.VERSION.SDK_INT >= 30) {
                    val insets = ViewCompat.getRootWindowInsets(window.decorView)
                    insets != null && insets.isVisible(WindowInsetsCompat.Type.statusBars()) == !enabled &&
                        insets.isVisible(WindowInsetsCompat.Type.navigationBars()) == !enabled
                } else {
                    val visibility = window.decorView.systemUiVisibility
                    (visibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0) == enabled &&
                        (visibility and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION != 0) == enabled
                }
                matches = keepScreenOn == enabled && barsMatch
            }
            matches
        }
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 20_000
        do {
            if (condition()) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        error(message)
    }

    private companion object {
        const val MODE_KEY = "terminal-mode"
        // Synthetic pairing; no desktop server or real pairing credentials are used.
        const val LOOPBACK_PAIRING =
            """{"version":1,"serviceID":"dedicated-mode-test","host":"127.0.0.1","port":1,"secret":"dGVzdA=="}"""
    }
}
