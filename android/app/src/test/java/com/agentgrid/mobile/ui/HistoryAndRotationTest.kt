package com.agentgrid.mobile.ui

import com.agentgrid.mobile.domain.*
import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.ExperimentalCoroutinesApi

class HistoryAndRotationTest {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `real rotation delay waits fifteen seconds and cancellation prevents background switching`() = runTest {
        var selected = DataUsageTab.CODEX
        launch { IdleDataRotation.advanceAfterDelay(selected) { selected = it } }
        runCurrent(); advanceTimeBy(14_999); runCurrent()
        assertEquals(DataUsageTab.CODEX, selected)
        advanceTimeBy(1); runCurrent()
        assertEquals(DataUsageTab.CLAUDE, selected)
        val paused = launch { IdleDataRotation.advanceAfterDelay(selected) { selected = it } }
        runCurrent(); advanceTimeBy(5_000); paused.cancel()
        advanceTimeBy(20_000); runCurrent()
        assertEquals(DataUsageTab.CLAUDE, selected)
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `rotation visits only enabled tabs and rescues a removed selection`() = runTest {
        val visible = IdleDataRotation.visibleTabs(listOf("codex", "hermes"))
        assertEquals(listOf(DataUsageTab.CODEX, DataUsageTab.HERMES), visible)
        var selected = DataUsageTab.CODEX
        launch { IdleDataRotation.advanceAfterDelay(selected, visible) { selected = it } }
        runCurrent(); advanceTimeBy(14_999); runCurrent()
        assertEquals(DataUsageTab.CODEX, selected)
        advanceTimeBy(1); runCurrent()
        assertEquals(DataUsageTab.HERMES, selected)
        assertEquals(DataUsageTab.CODEX, IdleDataRotation.next(selected, visible))
        assertEquals(DataUsageTab.HERMES, IdleDataRotation.currentVisible(DataUsageTab.CLAUDE, listOf(DataUsageTab.HERMES)))
        assertNull(IdleDataRotation.currentVisible(selected, emptyList()))
        var callbacks = 0
        for (tabs in listOf(emptyList(), listOf(DataUsageTab.HERMES))) {
            assertFalse(IdleDataRotation.allowed(true, true, emptyList(), tabs))
            IdleDataRotation.advanceAfterDelay(selected, tabs) { callbacks++ }
        }
        assertEquals(0, callbacks)
    }

    @Test fun `orphan pending requests pause rotation even with no task work`() {
        for (kind in PendingRequestKind.entries) {
            assertFalse(IdleDataRotation.allowed(true, true, emptyList(), pendingRequests = listOf(PendingRequest("not-yet-snapshotted", kind))))
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `manual tab or range interaction restarts a full fifteen second countdown`() = runTest {
        var selected = DataUsageTab.CODEX
        var timer = launch { IdleDataRotation.advanceAfterDelay(selected) { selected = it } }
        runCurrent(); advanceTimeBy(10_000); runCurrent()
        // DataDashboard cancels the keyed effect for either tab or range interactions.
        timer.cancel()
        timer = launch { IdleDataRotation.advanceAfterDelay(selected) { selected = it } }
        runCurrent(); advanceTimeBy(14_999); runCurrent()
        assertEquals(DataUsageTab.CODEX, selected)
        advanceTimeBy(1); runCurrent()
        assertEquals(DataUsageTab.CLAUDE, selected)
        timer.cancel()
    }

    @Test fun `pure model rows are identical regardless of historical reasoning depth`() {
        val day = LocalDate.of(2026, 11, 21)
        fun rows(effort: String?) = HermesHistoryPresentation.project(
            HermesUsageSnapshot(
                dailyUsage = listOf(DailyUsagePoint(day.toString(), totalTokens = 100)),
                modelUsage = listOf(ModelUsagePoint(day.toString(), "same-model", 100, effort)),
            ), UsageRange.SEVEN_DAYS, day,
        ).models
        assertEquals(rows("high"), rows(null))
    }

    @Test fun `native period totals include auxiliary models even when chart has main-only dates`() {
        val day = LocalDate.of(2026,11,21)
        val history = HermesUsageSnapshot(dailyUsage=listOf(DailyUsagePoint(day.toString(),totalTokens=100)),
            periods=listOf(HermesUsagePeriod(7,listOf(ModelTokenTotal("a",50),ModelTokenTotal("b",30),ModelTokenTotal("c",20),ModelTokenTotal("aux",20)),120,9.0)),
            dateBasis="native-session-start")
        val result = HermesHistoryPresentation.project(history,UsageRange.SEVEN_DAYS,day)
        assertEquals(120L,result.aggregate.totalTokens)
        assertEquals(9.0,result.aggregate.estimatedCostUSD!!,.0001)
        assertEquals(50f/120f,result.models.first().share,.0001f)
        assertEquals(100L,result.points.sumOf{it.totalTokens})
        assertEquals(3,result.models.size)
    }

    @Test fun `seven thirty and ninety day wire periods merge models across accounts without truncating totals`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        for (range in UsageRange.entries) {
            val history = json.decodeFromString<HermesUsageSnapshot>("""{
              "periods":[{"days":${range.days},"totalTokens":100,"estimatedCostUSD":9.0,"models":[
                {"model":"same","totalTokens":40,"provider":"a","account":"one","reasoningEffort":"high"},
                {"model":"same","totalTokens":20,"provider":"b","account":"two"},
                {"model":"second","totalTokens":20},{"model":"third","totalTokens":15},{"model":"fourth","totalTokens":5}
              ]}]
            }""")
            val view = HermesHistoryPresentation.project(history, range, LocalDate.of(2026, 11, 21))
            assertEquals(listOf("same", "second", "third"), view.models.map { it.model })
            assertEquals(60L, view.models.first().tokens)
            assertEquals(.6f, view.models.first().share, .0001f)
            assertEquals(100L, view.aggregate.totalTokens)
            assertEquals(9.0, view.aggregate.estimatedCostUSD!!, .0001)
            assertEquals(range.days, view.points.size)
        }
    }

    @Test fun `scheme A top three divide by ALL models and all model chart cost`() {
        val day = LocalDate.of(2026,11,21)
        val rows = listOf(ModelUsagePoint(day.toString(),"a",40,"high"),ModelUsagePoint(day.toString(),"a",10,"low"),
            ModelUsagePoint(day.toString(),"b",20),ModelUsagePoint(day.toString(),"c",15),ModelUsagePoint(day.toString(),"d",15))
        val h = HermesUsageSnapshot(capturedAt=1,dailyUsage=listOf(DailyUsagePoint(day.toString(),totalTokens=100,estimatedCostUSD=9.0)),modelUsage=rows)
        val p = HermesHistoryPresentation.project(h,UsageRange.SEVEN_DAYS,day)
        assertEquals(listOf("a","b","c"),p.models.map{it.model})
        assertEquals(.5f,p.models[0].share,0.0001f)
        assertEquals(50L,p.models[0].tokens)
        assertEquals(100L,p.points.sumOf{it.totalTokens})
        assertEquals(9.0,UsagePresentation.totalEstimatedCostUSD(p.points)!!,.0001)
        assertEquals(7,p.points.size)
    }
    @Test fun `history ranges use calendar days not last seven nonempty buckets`() {
        val day=LocalDate.of(2026,11,21)
        val h=HermesUsageSnapshot(dailyUsage=listOf(DailyUsagePoint("2026-10-01",totalTokens=500)),modelUsage=listOf(ModelUsagePoint("2026-10-01","old",500)))
        val p=HermesHistoryPresentation.project(h,UsageRange.SEVEN_DAYS,day)
        assertTrue(p.models.isEmpty());assertEquals(0L,p.points.sumOf{it.totalTokens})
    }
    @Test fun `unknown nonzero day prevents partial estimate`() {
        val points=listOf(DailyUsagePoint("2026-11-20",totalTokens=10,estimatedCostUSD=2.0),DailyUsagePoint("2026-11-21",totalTokens=20))
        assertNull(UsagePresentation.totalEstimatedCostUSD(points))
    }
    @Test fun `rotation only after full fifteen seconds and no work including pending approval`() {
        assertEquals(15_000L,IdleDataRotation.intervalMs)
        val idle=TaskSnapshot("a",AgentSource.HERMES_DESKTOP,"Hermes",lifecycle=AgentLifecycle.IDLE,startedAt=1,updatedAt=1)
        assertTrue(IdleDataRotation.allowed(true,true,listOf(idle)))
        val delegated = idle.copy(activeSubagents=2, activity=AgentActivity.DELEGATING)
        assertFalse(IdleDataRotation.allowed(true,true,listOf(delegated)))
        assertEquals("子代理工作中 · 2 个", taskStatusText(delegated))
        for(life in listOf(AgentLifecycle.STARTING,AgentLifecycle.RUNNING,AgentLifecycle.WAITING_APPROVAL,AgentLifecycle.WAITING_ANSWER))
            assertFalse(IdleDataRotation.allowed(true,true,listOf(idle.copy(lifecycle=life))))
        assertFalse(IdleDataRotation.allowed(false,true,emptyList()))
        assertFalse(IdleDataRotation.allowed(true,false,emptyList()))
        assertEquals(DataUsageTab.CLAUDE,IdleDataRotation.next(DataUsageTab.CODEX))
        assertEquals(DataUsageTab.HERMES,IdleDataRotation.next(DataUsageTab.CLAUDE))
        assertEquals(DataUsageTab.CODEX,IdleDataRotation.next(DataUsageTab.HERMES))
    }
}
