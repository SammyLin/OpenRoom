import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 兩種來源都切成 protocol 要求的固定 100ms／3200 bytes 幀，跟 `native/openroom-capture`
/// 的邏輯同一套（system 那條路直接沿用），mic 走 AVAudioEngine。
final class AudioCapture: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var level: Double = 0
    @Published var lastError: String? = nil

    var onFrame: ((Data) -> Void)?

    private var buffer = Data()
    private var stream: SCStream?
    private let audioEngine = AVAudioEngine()
    private var micRunning = false

    func start(source: AudioSource) async -> Bool {
        buffer.removeAll()
        lastError = nil
        switch source {
        case .system: return await startSystem()
        case .mic: return startMic()
        }
    }

    func stop() {
        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }
        if micRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            micRunning = false
        }
        DispatchQueue.main.async { self.level = 0 }
    }

    // MARK: - system audio (ScreenCaptureKit)

    private func startSystem() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                await setError(L("No display found. ScreenCaptureKit audio capture has to be bound to a display or window."))
                return false
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = SAMPLE_RATE
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true
            config.showsCursor = false
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "openroom.audio"))
            try await s.startCapture()
            stream = s
            return true
        } catch {
            await setError(String(
                format: L("System audio capture failed: %@. On first run you have to grant access in System Settings > Privacy & Security > Screen & System Audio Recording."),
                error.localizedDescription))
            return false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.floatsToS16LE(sampleBuffer) else { return }
        emit(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await setError(String(format: L("System audio capture stopped: %@"), error.localizedDescription))
        }
    }

    private static func floatsToS16LE(_ sampleBuffer: CMSampleBuffer) -> Data? {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return nil }
        let byteCount = Int(list.mBuffers.mDataByteSize)
        let floatCount = byteCount / MemoryLayout<Float32>.size
        let floats = data.bindMemory(to: Float32.self, capacity: floatCount)
        return int16LE(from: UnsafeBufferPointer(start: floats, count: floatCount))
    }

    // MARK: - mic (AVAudioEngine)

    private func startMic() -> Bool {
        let input = audioEngine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SAMPLE_RATE),
                                          channels: 1, interleaved: false) else { return false }
        guard let converter = AVAudioConverter(from: hwFormat, to: target) else {
            setErrorSync(String(format: L("Could not build a %lld Hz mono audio converter"), SAMPLE_RATE))
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1600, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = Double(SAMPLE_RATE) / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData?[0] else { return }
            let floats = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
            if let pcm = int16LE(from: floats) { self.emit(pcm) }
        }
        do {
            try audioEngine.start()
            micRunning = true
            return true
        } catch {
            setErrorSync(String(format: L("Microphone failed to start: %@"), error.localizedDescription))
            return false
        }
    }

    // MARK: - shared

    private func emit(_ pcm: Data) {
        buffer.append(pcm)
        // 音量表用最新一批算 RMS，跟切幀邏輯分開，不影響送出的資料
        updateLevel(pcm)
        while buffer.count >= FRAME_BYTES {
            onFrame?(buffer.prefix(FRAME_BYTES))
            buffer.removeFirst(FRAME_BYTES)
        }
    }

    private func updateLevel(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0 else { return }
        var sum: Double = 0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples { let v = Double(s) / 32768.0; sum += v * v }
        }
        let rms = (sum / Double(n)).squareRoot()
        let next = min(1.0, rms * 4)
        DispatchQueue.main.async { self.level = next }
    }

    @MainActor private func setError(_ msg: String) { lastError = msg }
    private func setErrorSync(_ msg: String) { DispatchQueue.main.async { self.lastError = msg } }
}

private func int16LE(from floats: UnsafeBufferPointer<Float32>) -> Data? {
    guard !floats.isEmpty else { return nil }
    var out = Data(capacity: floats.count * 2)
    for f in floats {
        let clamped = max(-1.0, min(1.0, f))
        var s = Int16(clamped * 32767.0).littleEndian
        withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
    }
    return out
}
