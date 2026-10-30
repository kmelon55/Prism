import Foundation

/// Incremental server-sent event framing. Works on bytes so UTF-8 may be split at any network boundary.
struct SSEParser {
    private var buffer: [UInt8] = []
    private var data: [UInt8] = []

    mutating func push(_ bytes: some Sequence<UInt8>) throws -> [String] {
        buffer.append(contentsOf: bytes)
        if buffer.count + data.count > 1_048_576 { throw AIError(L("The AI stream event is too large.")) }
        var events: [String] = []
        var start = 0
        while let end = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[start..<end]
            start = end + 1
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.isEmpty {
                if !data.isEmpty {
                    guard let event = String(bytes: data, encoding: .utf8) else { throw AIError(L("Invalid AI stream encoding.")) }
                    events.append(event)
                    data.removeAll()
                }
            } else if line.starts(with: "data:".utf8) {
                var value = line.dropFirst(5)
                if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
                if !data.isEmpty { data.append(UInt8(ascii: "\n")) }
                data.append(contentsOf: value)
            }
        }
        buffer.removeFirst(start)
        return events
    }

    mutating func finish() throws -> [String] {
        try push("\n\n".utf8)
    }
}

/// Rebuilds a complete provider response from streamed events: text, reasoning blocks, split tool arguments,
/// usage and citations. The result has the same shape as a non-streaming response.
struct StreamAccumulator {
    let provider: AIProvider
    private(set) var value: JSON = ["choices": [["message": ["role": "assistant", "content": ""], "finish_reason": nil]]]
    private(set) var text = ""
    private var terminal = false

    init(provider: AIProvider) {
        self.provider = provider
    }

    /// Returns true when the visible text changed.
    mutating func event(_ event: String) throws -> Bool {
        if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return false }
        guard let part = try? JSON.parse(event) else { throw AIError(L("Invalid AI stream format.")) }
        if part["error"].hasValue || part["type"] == "error" || part["type"] == "response.failed" {
            throw AIError(L("The answer stream stopped. Try again."))
        }
        let before = text.utf8.count
        if provider == .openai {
            switch part["type"].string {
            case "response.output_text.delta":
                if let delta = part["delta"].string { text += delta }
            case "response.completed", "response.incomplete":
                value = part["response"]
                terminal = true
            default: break
            }
        } else {
            let choice = part["choices"][0]
            if let delta = choice["delta"].object {
                var message = value["choices"][0]["message"]
                if let content = delta["content"]?.string {
                    text += content
                    message["content"] = .string(text)
                }
                for key in ["reasoning_content", "reasoning"] {
                    if let fragment = delta[key]?.string { message[key] = .string((message[key].string ?? "") + fragment) }
                }
                if let details = delta["reasoning_details"]?.array {
                    var accumulated = message["reasoning_details"].array ?? []
                    for detail in details { Self.merge(reasoning: detail, into: &accumulated) }
                    message["reasoning_details"] = .array(accumulated)
                }
                if let calls = delta["tool_calls"]?.array {
                    var accumulated = message["tool_calls"].array ?? []
                    for call in calls {
                        guard let index = call["index"].uint.map(Int.init) else { throw AIError(L("Invalid tool call order.")) }
                        if index >= 6 { throw AIError(L("Too many tool calls.")) }
                        while accumulated.count <= index {
                            accumulated.append(["id": "", "type": "function", "function": ["name": "", "arguments": ""]])
                        }
                        if let id = call["id"].string { accumulated[index]["id"] = .string(id) }
                        for key in ["name", "arguments"] {
                            if let fragment = call["function"][key].string {
                                accumulated[index]["function"][key] = .string((accumulated[index]["function"][key].string ?? "") + fragment)
                            }
                        }
                    }
                    message["tool_calls"] = .array(accumulated)
                }
                value["choices"][0]["message"] = message
            }
            if let reason = choice["finish_reason"].string {
                value["choices"][0]["finish_reason"] = .string(reason)
                terminal = true
            }
            for key in ["usage", "citations"] where part[key].hasValue {
                value[key] = part[key]
            }
        }
        if text.utf8.count > 1_048_576 { throw AIError(L("The AI response is too large.")) }
        return text.utf8.count != before
    }

    /// Text and summary deltas belong to the same reasoning block; encrypted blocks keep their boundaries.
    private static func merge(reasoning detail: JSON, into accumulated: inout [JSON]) {
        let field: String? = switch detail["type"].string {
        case "reasoning.text": "text"
        case "reasoning.summary": "summary"
        default: nil
        }
        if let field, var last = accumulated.last, last["type"] == detail["type"], last["index"] == detail["index"],
           last["id"].isNull || detail["id"].isNull || last["id"] == detail["id"] {
            for key in [field, "signature"] {
                if let fragment = detail[key].string { last[key] = .string((last[key].string ?? "") + fragment) }
            }
            for key in ["id", "format"] where detail[key].hasValue {
                last[key] = detail[key]
            }
            accumulated[accumulated.count - 1] = last
        } else {
            accumulated.append(detail)
        }
    }

    func finish() throws -> JSON {
        guard terminal else { throw AIError(L("The connection closed before the answer completed. Try again.")) }
        if value.data().count > 2_097_152 { throw AIError(L("The AI response is too large.")) }
        return value
    }
}
