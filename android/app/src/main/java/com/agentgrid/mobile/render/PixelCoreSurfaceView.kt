package com.agentgrid.mobile.render

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.RectF
import android.view.Choreographer
import android.view.View
import com.agentgrid.mobile.domain.AgentActivity
import com.agentgrid.mobile.domain.AgentLifecycle
import kotlin.math.ceil
import kotlin.math.min

private data class PixelFrame(
    val samples: List<PixelSample>,
    val color: Int,
)

private data class CachedGlowSprite(
    val bitmap: Bitmap,
    val baseCellSize: Float,
)

/**
 * 任务行左侧的 3×3 像素核心。
 *
 * 每个格子拥有独立的连续强度、位移、缩放和三层 Bloom。主体始终保持硬边，
 * 只有光晕层启用模糊，避免整枚图形变成一团发光贴图。
 */
class PixelCoreSurfaceView(context: Context) :
    View(context),
    Choreographer.FrameCallback {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val pixelRect = RectF()
    private val glowRect = RectF()
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private var glowSprite: CachedGlowSprite? = null
    private var glowTintColor: Int? = null
    private var renderState = PixelRenderState()
    private var currentFrameNanos = System.nanoTime()
    private var lastFrameNanos = 0L
    private var frameCallbackPosted = false
    private var motionEnabled = ValueAnimator.areAnimatorsEnabled()
    private var transitionFromSamples: List<PixelSample>? = null
    private var transitionFromColor: Int? = null

    init {
        setWillNotDraw(false)
    }

    fun updateState(state: PixelRenderState) {
        val animationsEnabled = ValueAnimator.areAnimatorsEnabled()
        if (state.requiresMotionRestart(renderState)) {
            val currentFrame = renderedFrame(currentFrameNanos)
            transitionFromSamples = currentFrame.samples.takeIf { animationsEnabled }
            transitionFromColor = currentFrame.color.takeIf { animationsEnabled }
            motionEnabled = animationsEnabled
            renderState = state.copy(changedAtNanos = System.nanoTime())
            currentFrameNanos = renderState.changedAtNanos
            postInvalidateOnAnimation()
        } else if (motionEnabled != animationsEnabled) {
            motionEnabled = animationsEnabled
            transitionFromSamples = null
            transitionFromColor = null
            postInvalidateOnAnimation()
        }
        scheduleFrameCallback()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        motionEnabled = ValueAnimator.areAnimatorsEnabled()
        scheduleFrameCallback()
    }

    override fun onDetachedFromWindow() {
        if (frameCallbackPosted) {
            Choreographer.getInstance().removeFrameCallback(this)
            frameCallbackPosted = false
        }
        super.onDetachedFromWindow()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        rebuildGlowBitmap(width, height)
    }

    override fun doFrame(frameTimeNanos: Long) {
        frameCallbackPosted = false
        if (!isAttachedToWindow) return
        val elapsed = (frameTimeNanos - renderState.changedAtNanos)
            .coerceAtLeast(0L) / 1_000_000_000.0
        val fps = PixelMotionEngine.targetFps(
            lifecycle = renderState.lifecycle,
            elapsed = elapsed,
            motionEnabled = motionEnabled,
        )
        if (fps > 0) {
            if (PixelMotionEngine.shouldRenderFrame(
                    lastFrameNanos = lastFrameNanos,
                    frameTimeNanos = frameTimeNanos,
                    fps = fps,
                )
            ) {
                currentFrameNanos = frameTimeNanos
                postInvalidateOnAnimation()
                lastFrameNanos = frameTimeNanos
            }
            scheduleFrameCallback()
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val frame = renderedFrame(currentFrameNanos)
        val samples = frame.samples
        val color = frame.color
        val elapsed = elapsedAt(currentFrameNanos)
        val burst = PixelMotionEngine.burst(renderState.lifecycle, elapsed)

        val side = min(width, height) * 0.62f
        val step = side / 3f
        val cell = step * 0.58f
        val centerX = width / 2f
        val centerY = height / 2f

        samples.forEach { sample ->
            val row = sample.index / 3 - 1
            val column = sample.index % 3 - 1
            val x = centerX + (column + sample.offsetX) * step
            val y = centerY + (row + sample.offsetY) * step
            val cellSide = cell * sample.scale
            pixelRect.set(
                x - cellSide / 2,
                y - cellSide / 2,
                x + cellSide / 2,
                y + cellSide / 2,
            )

            // 外、中、内三层 Bloom 已合成到缓存精灵；动画帧只提交一次贴图。
            val glowEnergy = PixelMotionEngine.glowEnergy(sample.intensity, burst)
            val cachedGlow = glowSprite
            if (glowEnergy > 0f && cachedGlow != null) {
                updateGlowTint(color)
                glowPaint.alpha = (glowEnergy.coerceIn(0f, 1f) * 255).toInt()
                val bitmapScale = cellSide / cachedGlow.baseCellSize
                val glowHalfWidth = cachedGlow.bitmap.width * bitmapScale / 2
                val glowHalfHeight = cachedGlow.bitmap.height * bitmapScale / 2
                glowRect.set(
                    x - glowHalfWidth,
                    y - glowHalfHeight,
                    x + glowHalfWidth,
                    y + glowHalfHeight,
                )
                canvas.drawBitmap(cachedGlow.bitmap, null, glowRect, glowPaint)
            }

            paint.isAntiAlias = false
            paint.color = color.withAlpha(0.04f)
            canvas.drawRect(pixelRect, paint)
            paint.color = color.withAlpha(0.03f + sample.intensity * 0.97f)
            canvas.drawRect(pixelRect, paint)
        }
    }

    /**
     * 软件模糊只在视图尺寸变化时计算一次；动画帧复用该位图并交给 GPU 移动、缩放。
     */
    private fun rebuildGlowBitmap(width: Int, height: Int) {
        glowSprite = null
        if (width <= 0 || height <= 0) return

        val baseCellSize = min(width, height) * 0.62f / 3f * 0.58f
        val specifications = listOf(
            PixelMotionEngine.OUTER_GLOW_OPACITY to PixelMotionEngine.OUTER_GLOW_RADIUS,
            PixelMotionEngine.MIDDLE_GLOW_OPACITY to PixelMotionEngine.MIDDLE_GLOW_RADIUS,
            PixelMotionEngine.INNER_GLOW_OPACITY to PixelMotionEngine.INNER_GLOW_RADIUS,
        )
        val maximumBlurRadius = specifications.maxOf { it.second } *
            resources.displayMetrics.density
        val padding = ceil(maximumBlurRadius * 2).toInt()
        val bitmapSize = ceil(baseCellSize).toInt() + padding * 2
        val bitmap = Bitmap.createBitmap(bitmapSize, bitmapSize, Bitmap.Config.ARGB_8888)
        val bitmapCanvas = Canvas(bitmap)
        specifications.forEach { (opacityMultiplier, radius) ->
            val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(
                    (opacityMultiplier * 255).toInt(),
                    255,
                    255,
                    255,
                )
                style = Paint.Style.FILL
                maskFilter = BlurMaskFilter(
                    radius * resources.displayMetrics.density,
                    BlurMaskFilter.Blur.NORMAL,
                )
            }
            bitmapCanvas.drawRect(
                padding.toFloat(),
                padding.toFloat(),
                padding + baseCellSize,
                padding + baseCellSize,
                bitmapPaint,
            )
        }
        glowSprite = CachedGlowSprite(
            bitmap = bitmap,
            baseCellSize = baseCellSize,
        )
    }

    private fun updateGlowTint(color: Int) {
        if (glowTintColor == color) return
        glowTintColor = color
        glowPaint.colorFilter = PorterDuffColorFilter(color, PorterDuff.Mode.SRC_IN)
    }

    private fun scheduleFrameCallback() {
        if (!isAttachedToWindow || frameCallbackPosted) return
        frameCallbackPosted = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    private fun renderedFrame(frameTimeNanos: Long): PixelFrame {
        val elapsed = elapsedAt(frameTimeNanos)
        val targetElapsed = if (motionEnabled) {
            elapsed
        } else {
            PixelMotionEngine.reducedMotionElapsed(renderState.lifecycle)
        }
        val targetSamples = PixelMotionEngine.sample(
            renderState.lifecycle,
            renderState.activity,
            targetElapsed,
        )
        val targetColor = PixelPalette.color(renderState.lifecycle, renderState.activity)
        val progress = if (motionEnabled) {
            PixelMotionEngine.transitionProgress(elapsed)
        } else {
            1f
        }
        val sourceSamples = transitionFromSamples
        val sourceColor = transitionFromColor

        if (sourceSamples == null || sourceColor == null || progress >= 1f) {
            transitionFromSamples = null
            transitionFromColor = null
            return PixelFrame(targetSamples, targetColor)
        }
        return PixelFrame(
            samples = PixelMotionEngine.blendSamples(sourceSamples, targetSamples, progress),
            color = PixelPalette.blend(sourceColor, targetColor, progress),
        )
    }

    private fun elapsedAt(frameTimeNanos: Long): Double =
        (frameTimeNanos - renderState.changedAtNanos)
            .coerceAtLeast(0L) / 1_000_000_000.0

    private fun Int.withAlpha(alpha: Float): Int = Color.argb(
        (alpha.coerceIn(0f, 1f) * 255).toInt(),
        Color.red(this),
        Color.green(this),
        Color.blue(this),
    )
}

object PixelPalette {
    fun color(lifecycle: AgentLifecycle, activity: AgentActivity?): Int = when (lifecycle) {
        AgentLifecycle.WAITING_APPROVAL -> Color.rgb(253, 186, 74)
        AgentLifecycle.WAITING_ANSWER -> Color.rgb(250, 204, 21)
        AgentLifecycle.SUCCEEDED -> Color.rgb(74, 222, 128)
        AgentLifecycle.INTERRUPTED, AgentLifecycle.OFFLINE -> Color.rgb(100, 116, 139)
        AgentLifecycle.IDLE -> Color.rgb(94, 234, 212)
        AgentLifecycle.STARTING -> Color.rgb(167, 139, 250)
        AgentLifecycle.RUNNING -> when (activity) {
            AgentActivity.READING,
            AgentActivity.SEARCHING,
            AgentActivity.BROWSING,
            -> Color.rgb(94, 234, 212)
            AgentActivity.EDITING -> Color.rgb(129, 140, 248)
            AgentActivity.EXECUTING -> Color.rgb(251, 146, 60)
            AgentActivity.TESTING -> Color.rgb(96, 165, 250)
            AgentActivity.DELEGATING,
            AgentActivity.THINKING,
            null,
            -> Color.rgb(232, 121, 249)
        }
    }

    fun blend(from: Int, to: Int, progress: Float): Int {
        val amount = progress.coerceIn(0f, 1f)
        return Color.rgb(
            lerp(Color.red(from), Color.red(to), amount),
            lerp(Color.green(from), Color.green(to), amount),
            lerp(Color.blue(from), Color.blue(to), amount),
        )
    }

    private fun lerp(from: Int, to: Int, progress: Float): Int =
        (from + (to - from) * progress).toInt().coerceIn(0, 255)
}
