import ScreenCaptureKit
import CoreMedia

let FRAME_BYTES = 3200 // 100ms @ 16kHz s16le mono，protocol.md 規定的固定長度

/// 把 ScreenCaptureKit 吐出來的 CMSampleBuffer（Float32，因為 SCStreamConfiguration
/// 已經指定 16kHz mono，不用自己重採樣）切成 protocol 要求的固定 100ms 幀。
final class AudioOutput: NSObject, SCStreamOutput {
    var onFrame: ((Data) -> Void)?
    private var buffer = Data()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = Self.extractS16LE(sampleBuffer) else { return }
        buffer.append(pcm)
        while buffer.count >= FRAME_BYTES {
            onFrame?(buffer.prefix(FRAME_BYTES))
            buffer.removeFirst(FRAME_BYTES)
        }
    }

    private static func extractS16LE(_ sampleBuffer: CMSampleBuffer) -> Data? {
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
        var out = Data(capacity: floatCount * 2)
        for i in 0..<floatCount {
            let clamped = max(-1.0, min(1.0, floats[i]))
            var s = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
        }
        return out
    }
}

final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        eprint("❌ SCStream 中斷: \(error)")
    }
}
