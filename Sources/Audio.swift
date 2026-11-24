import AVFoundation
import Accelerate
import Foundation
import Speech
import Synchronization

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias AudioChunks = AsyncThrowingStream<AVAudioPCMBuffer, Error>
typealias Preview = @Sendable (String) -> Void

// AVAudioEngine hands out reusable tap buffers. The consumer owns a copy until decoding finishes.
func copyPCM(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
    copy.frameLength = input.frameLength
    let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
    let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, target) {
        guard let dst = to.mData, let src = from.mData else { return nil }
        memcpy(dst, src, Int(from.mDataByteSize))
    }
    return copy
}

// The audio tap publishes one scalar. Drawing never waits on the audio thread.
final class AudioLevelMeter: Sendable {
    private let power = Atomic<UInt32>(0)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        var strongest: Float = 0
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = plane.mData else { continue }
            let count = Int(buffer.frameLength) * Int(plane.mNumberChannels)
            guard count > 0 else { continue }
            var meanSquare: Float = 0
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                vDSP_measqv(data.assumingMemoryBound(to: Float.self), 1, &meanSquare, vDSP_Length(count))
            case .pcmFormatFloat64:
                var value: Double = 0
                vDSP_measqvD(data.assumingMemoryBound(to: Double.self), 1, &value, vDSP_Length(count))
                meanSquare = Float(value)
            case .pcmFormatInt16:
                meanSquare = Self.meanSquare(data.assumingMemoryBound(to: Int16.self), count)
            case .pcmFormatInt32:
                meanSquare = Self.meanSquare(data.assumingMemoryBound(to: Int32.self), count)
            default: break
            }
            if meanSquare.isFinite { strongest = max(strongest, meanSquare) }
        }
        power.store(strongest.bitPattern, ordering: .relaxed)
    }

    private static func meanSquare<T: FixedWidthInteger>(_ samples: UnsafePointer<T>, _ count: Int) -> Float {
        let scale = 1 / (Float(T.max) + 1)
        var sum: Float = 0
        for i in 0..<count {
            let sample = Float(samples[i]) * scale
            sum += sample * sample
        }
        return sum / Float(count)
    }

    var level: CGFloat {
        let meanSquare = Float(bitPattern: power.load(ordering: .relaxed))
        let db = 10 * log10f(max(meanSquare, 1e-10))
        return CGFloat(min(1, max(0, (db + 55) / 47)))
    }
}

final class Microphone {
    let meter = AudioLevelMeter()
    private let engine = AVAudioEngine()
    private let channel = AudioChunks.makeStream(bufferingPolicy: .bufferingOldest(320))
    private var tapped = false
    private var configurationObserver: NSObjectProtocol?
    var chunks: AudioChunks { channel.stream }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError("没有可用的麦克风。") }
        let output = channel.continuation
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            meter.ingest(buffer)
            guard let owned = copyPCM(buffer) else { output.finish(throwing: VoiceError("无法读取音频。")); return }
            if case .dropped = output.yield(owned) {
                output.finish(throwing: VoiceError("识别服务未及时接收音频，请重试。"))
            }
        }
        tapped = true
        do { try engine.start() } catch { stop(); throw error }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in output.finish(throwing: VoiceError("麦克风已切换，请重新按住快捷键。")) }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapped {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        channel.continuation.finish()
    }
}

final class Resampler: @unchecked Sendable {
    private let lock = NSLock()
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    init(_ output: AVAudioFormat) { self.output = output }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if input.format == output { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: output)
            converter?.primeMethod = .none
        }
        let frames = ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 16
        guard let converter, let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else {
            throw VoiceError("无法转换麦克风音频格式。")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: result, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw failure ?? VoiceError("音频采样转换失败。") }
        return result.frameLength > 0 ? result : nil
    }
}

// Keep confirmed text independently of the live recognizer so a late failure in a long
// session can still be recovered. Audio buffers remain bounded by the microphone stream.
final class ConfirmedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var segment = ""
    // The cloud recognizer may revise the same sentence before its task ends.
    func updateSegment(_ finalSentences: String) {
        lock.lock(); defer { lock.unlock() }
        segment = finalSentences
    }
    func commitSegment() {
        lock.lock(); defer { lock.unlock() }
        text += segment
        segment = ""
    }
    func append(_ part: String) {
        lock.lock(); defer { lock.unlock() }
        text += part
    }
    func value() -> String {
        lock.lock(); defer { lock.unlock() }
        return (text + segment).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        return String((text.suffix(85) + segment.suffix(85)).suffix(85))
    }
}

enum AppleDictation {
    static func run(_ chunks: AudioChunks, confirmed: ConfirmedText = .init(), preview: @escaping Preview) async throws -> String {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw VoiceError("此设备不支持本机普通话听写。")
        }
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard await DictationTranscriber.installedLocales.contains(locale) else {
            throw VoiceError("请先在设置中准备中文听写资源。")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw VoiceError("系统未提供兼容的听写音频格式。")
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        let resampler = Resampler(format)
        let sequence = chunks.compactMap { buffer -> AnalyzerInput? in
            try Task.checkCancellation()
            return try resampler.convert(buffer).map { AnalyzerInput(buffer: $0) }
        }
        return try await withTaskCancellationHandler {
            let reader = Task {
                for try await item in module.results {
                    let text = String(item.text.characters)
                    if item.isFinal { confirmed.append(text) }
                    preview(item.isFinal ? confirmed.tail() : confirmed.tail() + text.suffix(85))
                }
                return confirmed.value()
            }
            do {
                if let end = try await analyzer.analyzeSequence(sequence) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await reader.value
            } catch {
                reader.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }

    static func prepare() async throws {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw VoiceError("此设备不支持本机普通话听写。")
        }
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install.downloadAndInstall()
        }
    }
}
