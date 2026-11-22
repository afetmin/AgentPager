package com.agentgrid.mobile

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.agentgrid.mobile.domain.HermesUsagePeriod
import com.agentgrid.mobile.domain.HermesUsageSnapshot
import com.agentgrid.mobile.domain.ModelTokenTotal
import com.agentgrid.mobile.network.PairingSummary
import com.agentgrid.mobile.ui.AgentGridScreen

/**
 * Device regression tests using only the platform instrumentation APIs.
 *
 * Run after installing the debug and androidTest APKs:
 * adb shell am instrument -w \
 *   com.agentgrid.mobile.test/com.agentgrid.mobile.DedicatedModeRegressionTest
 * No desktop connection is needed; pairing uses an unreachable loopback endpoint.
 */
class DedicatedModeRegressionTest : Instrumentation() {
    private var activity: MainActivity? = null

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val tests = listOf(
            "disabledPreferenceIsRespectedOnColdStart" to ::disabledPreferenceIsRespectedOnColdStart,
            "modeCanBeExitedAndReenteredWithoutRestart" to ::modeCanBeExitedAndReenteredWithoutRestart,
            "dataTabsPreserveCodexAndDedicatedMode" to ::dataTabsPreserveCodexAndDedicatedMode,
        )
        val settings = targetContext.getSharedPreferences("agentgrid-settings", Context.MODE_PRIVATE)
        val oldMode = settings.all["terminal-mode"] as? Boolean
        val pairing = targetContext.getSharedPreferences("agentgrid-pairing", Context.MODE_PRIVATE)
        val oldPairing = listOf("iv", "payload").associateWith { pairing.getString(it, null) }
        var failures = 0
        try {
            tests.forEachIndexed { index, (name, test) ->
                val status = Bundle().apply {
                    putString("class", this@DedicatedModeRegressionTest.javaClass.name)
                    putString("test", name)
                    putInt("current", index + 1)
                    putInt("numtests", tests.size)
                }
                sendStatus(1, status)
                try {
                    test()
                    status.putString("stream", ".")
                    sendStatus(0, status)
                } catch (error: Throwable) {
                    failures++
                    status.putString("stack", error.stackTraceToString())
                    status.putString("stream", "\n$name: ${error.stackTraceToString()}\n")
                    sendStatus(-2, status)
                } finally {
                    closeActivity()
                }
            }
        } finally {
            settings.edit().apply {
                if (oldMode == null) remove("terminal-mode") else putBoolean("terminal-mode", oldMode)
            }.commit()
            pairing.edit().apply {
                oldPairing.forEach { (key, value) ->
                    if (value == null) remove(key) else putString(key, value)
                }
            }.commit()
        }
        finish(Activity.RESULT_OK, Bundle().apply {
            putString("stream", "\nTests run: ${tests.size}, Failures: $failures\n")
        })
    }

    private fun disabledPreferenceIsRespectedOnColdStart() {
        check(settings().edit().putBoolean("terminal-mode", false).commit())
        launchActivity()
        assertWindowMode(false)
        openSettings()
        awaitLabel("进入专用模式")
    }

    private fun modeCanBeExitedAndReenteredWithoutRestart() {
        check(settings().edit().remove("terminal-mode").commit())
        launchActivity()
        assertWindowMode(true)
        openSettings()
        awaitLabel("退出专用模式")

        clickLabel("退出专用模式")
        awaitLabel("进入专用模式")
        assertWindowMode(false)
        check(!settings().getBoolean("terminal-mode", true)) { "Exit must persist disabled mode" }
        runOnMainSync { activity!!.onWindowFocusChanged(true) }
        assertWindowMode(false)

        val original = activity
        clickLabel("进入专用模式")
        awaitLabel("退出专用模式")
        check(activity === original) { "Entering dedicated mode must not restart the activity" }
        assertWindowMode(true)
        check(settings().getBoolean("terminal-mode", false)) { "Enter must persist enabled mode" }
        runOnMainSync { activity!!.onWindowFocusChanged(true) }
        assertWindowMode(true)

        closeActivity()
        launchActivity()
        assertWindowMode(true)
        openSettings()
        clickLabel("退出专用模式")
        assertWindowMode(false)
        closeActivity()
        launchActivity()
        assertWindowMode(false)
        openSettings()
        awaitLabel("进入专用模式")
    }

    private fun dataTabsPreserveCodexAndDedicatedMode() {
        check(settings().edit().putBoolean("terminal-mode", true).commit())
        launchActivity()
        awaitLabel("暂无已启用的数据源")
        check(findLabel("Claude 用量页签") == null)
        var demo by mutableStateOf(AgentGridUiState(
            pairing = PairingSummary("data-ui-test", "127.0.0.1", 1),
            enabledSources = listOf("codex", "hermes"),
            hermesUsage = HermesUsageSnapshot(
                capturedAt = System.currentTimeMillis(),
                periods = listOf(7, 30, 90).map { days -> HermesUsagePeriod(
                    days, listOf(ModelTokenTotal("model-a", 40, "high"), ModelTokenTotal("model-a", 30),
                        ModelTokenTotal("model-b", 20), ModelTokenTotal("model-c", 5), ModelTokenTotal("model-d", 5)),
                    100,
                ) },
            ),
        ))
        runOnMainSync {
            activity!!.setContent {
                AgentGridScreen(
                    state = demo, onPair = {}, onUnpair = {}, onControl = { _, _, _ -> }, onFocus = {},
                    onToggleDashboard = { demo = demo.copy(taskProjection = demo.taskProjection.togglingDashboard()) },
                    onToggleTerminal = {},
                )
            }
        }
        awaitLabel("CODEX 额度")
        check(findLabel("Claude 用量页签") == null) { "Disabled Claude must not have a tab" }
        clickLabel("Hermes 用量页签")
        awaitLabel("HERMES 模型用量")
        awaitLabel("model-a")
        awaitLabel("70%")
        awaitLabel("70 tokens")
        check(findLabel("深度未知") == null)
        check(findLabel("model-d") == null) { "Only three distinct models are shown" }
        awaitLabel("Bridge 离线 · 缓存统计")
        clickLabel("切换到任务列表")
        clickLabel("切换到状态显示栏")
        awaitLabel("HERMES 模型用量")
        clickLabel("Codex 用量页签")
        awaitLabel("CODEX 额度")
        awaitLabel("近期用量")
        clickLabel("显示最近 30 天用量")
        awaitLabel("30 天合计")
        assertWindowMode(true)
        // Dynamic capability removal must immediately rescue the current selection.
        runOnMainSync { demo = demo.copy(enabledSources = listOf("hermes")) }
        awaitLabel("HERMES 模型用量")
        check(findLabel("Codex 用量页签") == null)
        runOnMainSync { demo = demo.copy(enabledSources = emptyList()) }
        awaitLabel("暂无已启用的数据源")
    }

    private fun settings() =
        targetContext.getSharedPreferences("agentgrid-settings", Context.MODE_PRIVATE)

    private fun launchActivity() {
        val intent = Intent(targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(
                MainActivity.EXTRA_PAIRING,
                """{"version":1,"serviceID":"dedicated-mode-test","host":"127.0.0.1","port":1,"secret":"dGVzdA=="}""",
            )
        }
        activity = startActivitySync(intent) as MainActivity
        waitForIdleSync()
    }

    private fun closeActivity() {
        val current = activity ?: return
        runOnMainSync { current.finish() }
        await("Activity did not finish") { current.isDestroyed }
        activity = null
    }

    private fun openSettings() = clickLabel("打开设置")

    private fun awaitLabel(label: String) = await("Missing UI action: $label") { findLabel(label) != null }

    private fun clickLabel(label: String) {
        awaitLabel(label)
        var node = checkNotNull(findLabel(label))
        while (!node.isClickable) node = checkNotNull(node.parent) { "$label is not clickable" }
        check(node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "Could not click $label" }
        waitForIdleSync()
    }

    private fun findLabel(label: String): AccessibilityNodeInfo? =
        uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByText(label)?.firstOrNull {
            it.text?.toString() == label || it.contentDescription?.toString() == label
        }

    private fun assertWindowMode(enabled: Boolean) {
        await("Expected dedicated mode=$enabled, including system bars and keep-screen-on") {
            var matches = false
            runOnMainSync {
                val window = activity!!.window
                val insets = ViewCompat.getRootWindowInsets(window.decorView)
                val keepScreenOn = window.attributes.flags and
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
                matches = insets != null && keepScreenOn == enabled &&
                    insets.isVisible(WindowInsetsCompat.Type.statusBars()) == !enabled &&
                    insets.isVisible(WindowInsetsCompat.Type.navigationBars()) == !enabled
            }
            matches
        }
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            if (condition()) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        error(message)
    }
}
