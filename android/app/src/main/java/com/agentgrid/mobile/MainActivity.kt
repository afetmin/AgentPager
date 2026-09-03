package com.agentgrid.mobile

import android.os.Bundle
import android.util.Base64
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.agentgrid.mobile.ui.AgentGridScreen

class MainActivity : ComponentActivity() {
    private val viewModel: AgentGridViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterTerminalMode()
        importPairing(intent)

        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            AgentGridScreen(
                state = state,
                onPair = viewModel::pair,
                onUnpair = viewModel::unpair,
                onControl = viewModel::control,
                onFocus = viewModel::focus,
                onToggleDashboard = viewModel::toggleDashboard,
                onExitTerminal = {
                    viewModel.setTerminalMode(false)
                    exitTerminalMode()
                },
            )
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        importPairing(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && viewModel.state.value.terminalMode) {
            enterTerminalMode()
        }
    }

    private fun enterTerminalMode() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun exitTerminalMode() {
        WindowCompat.setDecorFitsSystemWindows(window, true)
        WindowInsetsControllerCompat(window, window.decorView)
            .show(WindowInsetsCompat.Type.systemBars())
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun importPairing(intent: android.content.Intent) {
        intent.getStringExtra(EXTRA_PAIRING)?.let(viewModel::pair)
        intent.getStringExtra(EXTRA_PAIRING_BASE64)?.let { encoded ->
            runCatching {
                Base64.decode(encoded, Base64.DEFAULT).decodeToString()
            }.getOrNull()?.let(viewModel::pair)
        }
    }

    companion object {
        const val EXTRA_PAIRING = "pairing"
        const val EXTRA_PAIRING_BASE64 = "pairingBase64"
    }
}
