import AVFoundation

@MainActor protocol WheelAudioOutput: AnyObject {
    func prepare() throws
    func play(tone: Int)
    func stop()
}

/// Prepare once on presentation; the highlight path only schedules a buffer.
/// Dismissal releases the output engine so no audio work continues while idle.
@MainActor final class WheelFeedback {
    private let makeOutput: @MainActor () -> any WheelAudioOutput
    private let uptime: @MainActor () -> TimeInterval
    private var output: (any WheelAudioOutput)?
    private var nextTone = 0
    private var lastPlayed: TimeInterval?

    init(makeOutput: @escaping @MainActor () -> any WheelAudioOutput = { PreparedWheelAudio() },
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.makeOutput = makeOutput
        self.uptime = uptime
    }

    func prepare() {
        guard output == nil else { return }
        let candidate = makeOutput()
        do {
            try candidate.prepare()
            output = candidate
            nextTone = 0
            lastPlayed = nil
        } catch {
            // Sound is optional; a failed output device must not block the wheel.
            candidate.stop()
        }
    }

    func selection() {
        guard let output else { return }
        let now = uptime()
        // Suppress boundary jitter without queuing stale sounds behind the cursor.
        if let lastPlayed, now - lastPlayed < 0.045 { return }
        self.lastPlayed = now
        output.play(tone: nextTone)
        nextTone = (nextTone + 1) % 2
    }

    func stop() {
        output?.stop()
        output = nil
        lastPlayed = nil
    }
}

/// Output only: no input node, microphone access, files or background timer.
@MainActor final class PreparedWheelAudio: WheelAudioOutput {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []

    func prepare() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw CocoaError(.coderInvalidValue)
        }
        for frequency in [1_175.0, 1_395.0] {
            guard let buffer = Self.tone(frequency: frequency, format: format) else {
                throw CocoaError(.coderInvalidValue)
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
            buffers.append(buffer)
        }
        engine.mainMixerNode.outputVolume = 0.12
        engine.prepare()
        try engine.start()
        for player in players { player.play() }
    }

    func play(tone: Int) {
        guard engine.isRunning, players.indices.contains(tone), buffers.indices.contains(tone) else { return }
        // Alternating nodes let the previous tone finish its short decay.
        players[tone].scheduleBuffer(buffers[tone], at: nil, options: .interrupts)
    }

    func stop() {
        for player in players { player.stop() }
        engine.stop()
        players.removeAll()
        buffers.removeAll()
    }

    private static func tone(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.055
        let count = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / format.sampleRate
            let attack = min(1, time / 0.003)
            let release = min(1, (duration - time) / 0.015)
            let envelope = attack * release * exp(-time * 52)
            let signal = sin(2 * .pi * frequency * time) + 0.24 * sin(2 * .pi * frequency * 2.01 * time)
            samples[index] = Float(max(-1, min(1, signal * envelope * 0.65)))
        }
        return buffer
    }
}
