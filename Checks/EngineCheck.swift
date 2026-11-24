import AVFoundation
import Foundation
import Network
import Speech

// A loopback peer talks the actual WebSocket wire protocol to URLSession.
private final class MockASR {
    let listener: NWListener
    let queue = DispatchQueue(label: "pressspeak.check.peer")
    var sessions = 0
    var bytes = 0
    var connections = [NWConnection]()
    enum Failure { case none, start, finish }
    let failure: Failure
    init(failure: Failure = .none) throws {
        self.failure = failure
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { c in
            self.connections.append(c)
            c.start(queue: self.queue)
            self.receive(c, part: self.connections.count)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { reply in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    reply.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    reply.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "ws://127.0.0.1:\(port)/test")!
    }
    private func send(_ c: NWConnection, _ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "event", metadata: [meta])
        c.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
    private func receive(_ c: NWConnection, part: Int, taskID: String? = nil) {
        c.receiveMessage { data, ctx, _, error in
            guard error == nil, let data, !data.isEmpty,
                  let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
            if meta.opcode == .binary {
                precondition(taskID != nil && data.count <= 3200 && data.count.isMultiple(of: 2))
                self.bytes += data.count
                self.receive(c, part: part, taskID: taskID)
                return
            }
            precondition(meta.opcode == .text)
            let event = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let header = event["header"] as! [String: String]
            let id = header["task_id"]!
            precondition(UUID(uuidString: id) != nil && header["streaming"] == "duplex")
            let payload = event["payload"] as! [String: Any]
            precondition((payload["input"] as? [String: String])?.isEmpty == true)
            func reply(_ name: String, payload: [String: Any] = [:]) {
                self.send(c, ["header": ["event": name, "task_id": id], "payload": payload])
            }
            func sentence(_ id: Int, _ text: String, final: Bool) {
                reply("result-generated", payload: ["output": ["sentence": ["sentence_id": id, "text": text, "sentence_end": final]]])
            }
            switch header["action"] {
            case "run-task":
                precondition(taskID == nil && payload["model"] as? String == "qwen-audio-3.1-asr-flash-message")
                precondition(payload["task_group"] as? String == "audio" && payload["task"] as? String == "asr" && payload["function"] as? String == "recognition")
                let params = payload["parameters"] as! [String: Any]
                precondition(params["sample_rate"] as? Int == 16000 && params["format"] as? String == "pcm")
                precondition(params["disfluency_removal_enabled"] as? Bool == true && params["intermediate_result_enabled"] as? Bool == true)
                self.sessions += 1
                if self.failure == .start {
                    self.send(c, ["header": ["event":"task-failed", "task_id":id, "error_code":"Model.AccessDenied"], "payload": [:]])
                    return
                }
                reply("task-started")
                reply("result-generated", payload: ["output": ["sentence": ["heartbeat": true, "sentence_id": 0]]])
                sentence(1, "嗯，就是，草稿", final: false)
            case "finish-task":
                precondition(taskID == id)
                sentence(2, "。", final: true)
                sentence(1, "旧结果", final: true)
                sentence(1, "段\(part)", final: true)
                sentence(1, "迟到的草稿", final: false)
                if self.failure == .finish {
                    self.send(c, ["header": ["event":"task-failed", "task_id":id, "error_code":"TestFailure"], "payload": [:]])
                } else { reply("task-finished") }
            default: preconditionFailure("Unexpected ASR action")
            }
            self.receive(c, part: part, taskID: id)
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
}

private func fileStream(_ url: URL) throws -> AudioChunks {
    let file = try AVAudioFile(forReading: url)
    let pair = AudioChunks.makeStream()
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
        try file.read(into: buffer)
        if buffer.frameLength > 0 { pair.continuation.yield(buffer) }
    }
    pair.continuation.finish()
    return pair.stream
}

@main struct EngineCheck {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--live") {
            let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw VoiceError("无法取得北京地域的 API Key。") }
            let sample = try fileStream(url)
            let paced = AudioChunks { continuation in
                let feeder = Task {
                    do {
                        for try await chunk in sample {
                            continuation.yield(chunk)
                            try await Task.sleep(for: .seconds(Double(chunk.frameLength) / chunk.format.sampleRate))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in feeder.cancel() }
            }
            let final = try await AliyunDictation.run(paced, key: key) { _ in }
            guard !final.isEmpty else { throw VoiceError("云端测试没有返回终稿。") }
            print("\(AliyunDictation.model) 云端终稿：\(final)")
            return
        }
        let local = try await AppleDictation.run(fileStream(url)) { _ in }
        print("Apple final:", local)
        guard local.contains("明天"), local.contains("提醒") else { throw VoiceError("中文终稿不完整") }
        let mock = try MockASR()
        let endpoint = try await mock.start()
        let result = try await AliyunDictation.run(fileStream(url), key: "test-only", endpoint: endpoint, segmentSeconds: 2) { _ in }
        let (count, bytes) = mock.queue.sync { (mock.sessions, mock.bytes) }
        mock.stop()
        let source = try AVAudioFile(forReading: url)
        let expectedBytes = Int(Double(source.length) / source.processingFormat.sampleRate * 32000)
        precondition(count >= 2 && abs(bytes - expectedBytes) < 128)
        precondition(result == (1...count).map { "段\($0)。" }.joined())
        print("Cloud loopback: \(count) sessions, \(bytes) PCM bytes, ordered final:", result)
        let fail = try MockASR(failure: .finish)
        let bad = try await fail.start()
        let confirmed = ConfirmedText()
        do {
            _ = try await AliyunDictation.run(fileStream(url), key: "test-only", endpoint: bad, confirmed: confirmed) { _ in }
            throw VoiceError("服务端报错未传递到调用方")
        } catch {
            guard error.localizedDescription.contains("TestFailure"), confirmed.value() == "段1。" else { throw error }
        }
        fail.stop()
        let denied = try MockASR(failure: .start)
        let unauthorized = try await denied.start()
        do {
            _ = try await AliyunDictation.run(fileStream(url), key: "test-only", endpoint: unauthorized) { _ in }
            throw VoiceError("启动失败后仍在发送音频")
        } catch {
            guard error.localizedDescription.contains("Model.AccessDenied"), denied.queue.sync(execute: { denied.bytes }) == 0
            else { throw error }
        }
        denied.stop()
        print("Cloud error handling: passed")
    }
}
