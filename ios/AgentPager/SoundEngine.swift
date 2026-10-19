import AVFoundation
import AgentGridShared
import UIKit

/// 用 AVAudioEngine 播放合成的提示音。走媒体通道（`.playback`），与 Android 端一致：
/// 专用终端常亮在前台，提示音不应被静音拨片吞掉；同时与其他音频混音，不打断用户的音乐。
@MainActor
final class SoundEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [ArcadeSoundCue: AVAudioPCMBuffer] = [:]
    private var configuredSampleRate: Double?

    init() {
        // 引擎与应用同生命周期，观察者不需要单独移除。
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // 路由变化（耳机插拔、蓝牙）后引擎会停止，下次播放时重新配置。
            MainActor.assumeIsolated { self?.configuredSampleRate = nil }
        }
    }

    func play(_ cue: ArcadeSoundCue) {
        guard let buffer = prepareBuffer(for: cue) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        if cue == .inputRequired {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func prepareBuffer(for cue: ArcadeSoundCue) -> AVAudioPCMBuffer? {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let rate = session.sampleRate >= 8_000 ? session.sampleRate : Double(ArcadeSoundSynthesizer.defaultSampleRate)
            if configuredSampleRate != rate || !engine.isRunning {
                try configure(sampleRate: rate)
            }
            if let cached = buffers[cue] { return cached }

            let samples = ArcadeSoundSynthesizer.render(cue, sampleRate: Int(rate))
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            buffers[cue] = buffer
            return buffer
        } catch {
            return nil
        }
    }

    private func configure(sampleRate: Double) throws {
        engine.stop()
        player.stop()
        if player.engine == nil { engine.attach(player) }
        engine.disconnectNodeOutput(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.coderInvalidValue)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers.removeAll()
        engine.prepare()
        try engine.start()
        configuredSampleRate = sampleRate
    }
}
