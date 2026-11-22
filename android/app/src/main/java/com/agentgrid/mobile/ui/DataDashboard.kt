package com.agentgrid.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.agentgrid.mobile.domain.HermesUsageSnapshot
import com.agentgrid.mobile.domain.EnabledDataSources
import com.agentgrid.mobile.domain.StateSnapshotPayload
import com.agentgrid.mobile.domain.PendingRequest
import com.agentgrid.mobile.domain.TaskSnapshot
import com.agentgrid.mobile.domain.UsageSnapshot
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

internal enum class DataUsageTab(val label: String) {
    CODEX("Codex"), CLAUDE("Claude"), HERMES("Hermes"),
}

@Composable
internal fun DataDashboard(
    usage: UsageSnapshot?, tasks: List<TaskSnapshot>, connected: Boolean,
    selectedTab: DataUsageTab, onTabSelected: (DataUsageTab) -> Unit,
    modifier: Modifier = Modifier, hermesUsage: HermesUsageSnapshot? = null, visible: Boolean = true,
    enabledSources: List<String>? = null,
    pendingRequests: List<PendingRequest> = emptyList(),
) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var manualSelection by remember { mutableIntStateOf(0) }
    val latestSelection by rememberUpdatedState(onTabSelected)
    val visibleTabs = IdleDataRotation.visibleTabs(EnabledDataSources.resolve(
        StateSnapshotPayload(tasks = tasks, usage = usage, hermesUsage = hermesUsage, enabledSources = enabledSources),
    ))
    val activeTab = IdleDataRotation.currentVisible(selectedTab, visibleTabs)
    LaunchedEffect(activeTab, selectedTab) {
        if (activeTab != null && activeTab != selectedTab) latestSelection(activeTab)
    }
    val rotate = IdleDataRotation.allowed(connected, visible && resumed, tasks, visibleTabs, pendingRequests)
    LaunchedEffect(rotate, activeTab, visibleTabs, manualSelection) {
        if (rotate && activeTab != null) {
            IdleDataRotation.advanceAfterDelay(activeTab, visibleTabs) { latestSelection(it) }
        }
    }
    var hermesRange by rememberSaveable { mutableStateOf(UsageRange.SEVEN_DAYS) }
    val tabStates = rememberSaveableStateHolder()
    Column(modifier = modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 36.dp).height(44.dp).selectableGroup(), verticalAlignment = Alignment.CenterVertically) {
            visibleTabs.forEach { tab ->
                val selected = activeTab == tab
                Column(
                    modifier = Modifier.widthIn(min = 80.dp)
                        .background(if (selected) AgentGridColors.SurfaceRaised else Color.Transparent).focusHighlight()
                        .selectable(selected = selected, role = Role.Tab, onClick = { manualSelection++; onTabSelected(tab) })
                        .semantics { contentDescription = "${tab.label} 用量页签" }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(tab.label, color = if (selected) AgentGridColors.Cyan else AgentGridColors.Muted,
                        fontSize = 11.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
        if (activeTab == null) {
            Column(Modifier.fillMaxWidth().height(310.dp).padding(36.dp), verticalArrangement = Arrangement.Center) {
                Text("暂无已启用的数据源", color = AgentGridColors.Text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text("请在 PC Bridge 启用数据源；旧版 Bridge 需等待首份用量或任务快照。", color = AgentGridColors.Muted, fontSize = 12.sp)
            }
        } else tabStates.SaveableStateProvider(activeTab) {
        when (activeTab) {
            DataUsageTab.CODEX -> UsageDashboard(usage = usage, connected = connected, onInteraction = { manualSelection++ })
            DataUsageTab.HERMES -> HermesDataDashboard(hermesUsage, connected, hermesRange) { manualSelection++; hermesRange = it }
            DataUsageTab.CLAUDE -> Column(Modifier.fillMaxWidth().height(310.dp).padding(36.dp), verticalArrangement = Arrangement.Center) {
                Text("Claude", color = AgentGridColors.Text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(12.dp))
                Text("暂无 Claude 用量统计", color = AgentGridColors.Muted, fontSize = 13.sp)
                Text("当前仅接收工作状态；未提供用量不代表零消耗。", color = AgentGridColors.Dimmed, fontSize = 10.sp)
            }
        }
        }
    }
}

@Composable
private fun HermesDataDashboard(history: HermesUsageSnapshot?, connected: Boolean, range: UsageRange, onRangeSelected: (UsageRange) -> Unit) {
    val now by produceState(System.currentTimeMillis()) {
        while (true) { value = System.currentTimeMillis(); delay(1_000) }
    }
    val view = HermesHistoryPresentation.project(history, range)
    val unavailable = history == null || history.dateBasis == "unavailable"
    val partial = unavailable || view.isPartial || !connected || now - (history?.capturedAt ?: 0) >= 180_000
    BoxWithConstraints(Modifier.fillMaxWidth().height(310.dp).padding(horizontal = 36.dp, vertical = 20.dp)) {
        val leftWidth = if (maxWidth < 700.dp) 226.dp else 270.dp
        Row(Modifier.fillMaxSize()) {
            Column(Modifier.width(leftWidth).fillMaxHeight(), verticalArrangement = Arrangement.SpaceBetween) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("HERMES 模型用量", color = AgentGridColors.Text, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    Text("近 ${range.days} 天 · 前三模型 / 全部用量", color = AgentGridColors.Muted, fontSize = 9.sp)
                }
                if (view.models.isEmpty()) {
                    Text(if (unavailable) "等待 Hermes 历史统计" else "所选时段暂无模型用量", color = AgentGridColors.Muted, fontSize = 12.sp)
                }
                view.models.forEach { model ->
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(if (model.model == "unknown") "未记录模型" else model.model,
                                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                                color = AgentGridColors.Text, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            Text("${(model.share * 100).roundToInt()}%", color = AgentGridColors.Cyan, fontSize = 10.sp,
                                modifier = Modifier.padding(start = 6.dp))
                        }
                        Text("${UsagePresentation.compactTokens(model.tokens)} tokens",
                            color = AgentGridColors.Muted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        LinearProgressIndicator(progress = { model.share }, color = AgentGridColors.Cyan,
                            trackColor = AgentGridColors.Divider, gapSize = 0.dp, drawStopIndicator = {},
                            modifier = Modifier.fillMaxWidth().height(4.dp).semantics { contentDescription = "${model.model} 占全部用量 ${(model.share * 100).roundToInt()}%" })
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(if (!connected) "Bridge 离线 · 缓存统计" else if (unavailable) "请在 PC 的 HERMES 设置中填写服务地址" else UsagePresentation.freshnessText(history?.capturedAt, now),
                        color = if (partial) AgentGridColors.Orange else AgentGridColors.Dimmed, fontSize = 8.sp)
                    Text("按会话起始日归档 · 非额度进度", color = AgentGridColors.Dimmed, fontSize = 8.sp)
                    history?.sourceNote?.let { Text(it, color = AgentGridColors.Muted, fontSize = 8.sp, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                }
            }
            Box(Modifier.padding(horizontal = 24.dp).width(1.dp).fillMaxHeight().background(AgentGridColors.Divider))
            HistoryPanel(allPoints = view.points, isPartial = partial, selectedRange = range,
                aggregate = view.aggregate,
                onRangeSelected = onRangeSelected, modifier = Modifier.weight(1f).fillMaxHeight(),
                partialMessage = if (unavailable) "等待历史统计，不将缺失数据当作零用量" else "统计暂不完整或已离线，费用暂不显示")
        }
    }
}
