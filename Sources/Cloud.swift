import AVFoundation
import Foundation

private final class CloudSession {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let taskID = UUID().uuidString.lowercased()

    init(endpoint: URL, key: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 16
        config.timeoutIntervalForResource = 95
        session = URLSession(configuration: config)
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func send(_ action: String, payload: [String: Any]) async throws {
        let event: [String: Any] = ["header": ["action": action, "task_id": taskID, "streaming": "duplex"],
                                    "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive() async throws -> (event: String, payload: [String: Any]) {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw VoiceError("云端返回了未知格式。")
        }
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = frame["header"] as? [String: Any], header["task_id"] as? String == taskID,
              let event = header["event"] as? String else { throw VoiceError("阿里云返回了无法识别的任务事件。") }
        if event == "task-failed" {
            let code = (header["error_code"] as? String ?? "ASR").prefix(80)
            throw VoiceError("阿里云识别失败（\(code)）。请检查北京业务空间中的模型权限、Key 和额度。")
        }
        return (event, frame["payload"] as? [String: Any] ?? [:])
    }

    private func watchdog(_ seconds: Int) -> DispatchWorkItem {
        let socket = self.socket
        let item = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
        return item
    }

    private func start() async throws {
        socket.resume()
        let timeout = watchdog(12)
        defer { timeout.cancel() }
        let params: [String: Any] = ["format": "pcm", "sample_rate": 16000, "language_hints": ["zh"],
                                     "disfluency_removal_enabled": true, "intermediate_result_enabled": true]
        try await send("run-task", payload: ["task_group": "audio", "task": "asr", "function": "recognition",
                                             "model": AliyunDictation.model, "parameters": params, "input": [:]])
        guard try await receive().event == "task-started" else { throw VoiceError("未收到阿里云任务启动确认。") }
    }

    private func sendAudio(first: Data, next: () async throws -> Data?, byteLimit: Int) async throws {
        var chunk: Data? = first
        var sent = 0
        var pending = Data()
        let frameBytes = 3200 // 100 ms, mono signed 16-bit PCM at 16 kHz
        while let pcm = chunk {
            try Task.checkCancellation()
            pending.append(pcm)
            while pending.count >= frameBytes {
                try await socket.send(.data(pending.prefix(frameBytes)))
                pending.removeFirst(frameBytes)
                sent += frameBytes
            }
            if sent + pending.count >= byteLimit { break }
            chunk = try await next()
        }
        if !pending.isEmpty { try await socket.send(.data(pending)) }
        try await send("finish-task", payload: ["input": [:]])
    }

    private func receiveResults(confirmed: ConfirmedText, preview: Preview) async throws {
        let prefix = confirmed.tail()
        var sentences: [Int: String] = [:]
        var finalIDs = Set<Int>()
        while true {
            try Task.checkCancellation()
            let (event, payload) = try await receive()
            switch event {
            case "result-generated":
                guard let output = payload["output"] as? [String: Any], let sentence = output["sentence"] as? [String: Any]
                else { throw VoiceError("阿里云未返回有效的识别句子。") }
                if sentence["heartbeat"] as? Bool == true { continue }
                guard let id = sentence["sentence_id"] as? Int, let text = sentence["text"] as? String else {
                    throw VoiceError("阿里云识别结果缺少句子编号或文本。")
                }
                let final = sentence["sentence_end"] as? Bool == true
                if !final && finalIDs.contains(id) { continue }
                sentences[id] = text
                if final {
                    finalIDs.insert(id)
                    confirmed.updateSegment(finalIDs.sorted().compactMap { sentences[$0] }.joined())
                }
                preview(prefix + sentences.keys.sorted().compactMap { sentences[$0] }.joined())
            case "task-finished":
                return
            default: continue
            }
        }
    }

    func run(first: Data, next: @escaping () async throws -> Data?, byteLimit: Int,
             confirmed: ConfirmedText, preview: @escaping Preview) async throws {
        do {
            try await start()
            // Receive final and intermediate events while audio is still being sent.
            // Either half can fail. Closing the socket also wakes the other half.
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await self.receiveResults(confirmed: confirmed, preview: preview)
                    return false
                }
                group.addTask {
                    try await self.sendAudio(first: first, next: next, byteLimit: byteLimit)
                    return true
                }
                var finishTimeout: DispatchWorkItem?
                defer { finishTimeout?.cancel() }
                do {
                    while let senderFinished = try await group.next() {
                        if senderFinished { finishTimeout = watchdog(15) }
                    }
                } catch {
                    group.cancelAll()
                    close()
                    throw error
                }
            }
        } catch {
            if let status = (socket.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
                throw VoiceError("阿里云鉴权失败（HTTP \(status)）。请检查北京地域的 API Key 和模型权限。")
            }
            throw error
        }
    }
}

enum AliyunDictation {
    static let model = "qwen-audio-3.1-asr-flash-message"
    static let beijing = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!

    static func run(_ chunks: AudioChunks, key: String, endpoint: URL = beijing,
                    segmentSeconds: Int = 48, confirmed: ConfirmedText = .init(), preview: @escaping Preview) async throws -> String {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let resampler = Resampler(format)
        var iterator = chunks.makeAsyncIterator()
        func nextPCM() async throws -> Data? {
            while let chunk = try await iterator.next() {
                try Task.checkCancellation()
                if let pcm = try resampler.convert(chunk), let samples = pcm.int16ChannelData {
                    return Data(bytes: samples[0], count: Int(pcm.frameLength) * 2)
                }
            }
            return nil
        }
        while let first = try await nextPCM() {
            let connection = CloudSession(endpoint: endpoint, key: key)
            defer { connection.close() }
            try await withTaskCancellationHandler {
                try await connection.run(first: first, next: nextPCM, byteLimit: segmentSeconds * 32000,
                                         confirmed: confirmed, preview: preview)
            } onCancel: { connection.close() }
            confirmed.commitSegment()
        }
        return confirmed.value()
    }
}
