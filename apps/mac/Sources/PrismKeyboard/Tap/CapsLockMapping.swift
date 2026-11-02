import Foundation

/// Turns Caps Lock into F18 with `hidutil`, so the event tap sees its presses and releases instead of a lock
/// toggle, and the Caps Lock light stays off.
///
/// The mapping lives in the HID system until restart and is merged with mappings other tools set: Prism adds or
/// removes only its own entry. If Prism quits without removing it, Caps Lock does nothing until Prism starts again.
enum CapsLockMapping {
    struct Entry: Equatable, Sendable {
        var source: UInt64
        var destination: UInt64
    }

    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D
    static let entry = Entry(source: capsLock, destination: f18)

    /// Adds or removes Prism's entry when it differs from what is wanted. Runs `hidutil`, so call it off the main thread.
    static func apply(_ wanted: Bool) {
        guard let output = run(["property", "--get", "UserKeyMapping"]) else { return }
        let current = parse(output)
        let next = merged(current, wanted: wanted)
        guard next != current else { return }
        _ = run(["property", "--set", json(next)])
    }

    static func merged(_ current: [Entry], wanted: Bool) -> [Entry] {
        var next = current.filter { $0 != entry }
        if wanted {
            next.removeAll { $0.source == capsLock }
            next.append(entry)
        }
        return next
    }

    /// Reads `hidutil property --get UserKeyMapping`, a property-list style dump with decimal values.
    static func parse(_ output: String) -> [Entry] {
        output.components(separatedBy: "{").dropFirst().compactMap { block in
            func value(_ key: String) -> UInt64? {
                guard let range = block.range(of: key) else { return nil }
                let digits = block[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
                return UInt64(digits)
            }
            guard let source = value("HIDKeyboardModifierMappingSrc"), let destination = value("HIDKeyboardModifierMappingDst") else { return nil }
            return Entry(source: source, destination: destination)
        }
    }

    static func json(_ entries: [Entry]) -> String {
        let items = entries.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}" }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
