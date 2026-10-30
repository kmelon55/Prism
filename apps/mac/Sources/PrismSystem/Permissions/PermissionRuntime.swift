import Foundation

/// The binary macOS checks permissions for, ported from `permissions.rs`. A development executable or an ad-hoc
/// rebuild can be a different TCC client from the installed Prism.app, which explains "enabled but not working".
struct PermissionRuntime: Equatable, Sendable {
    var executablePath: String
    var permissionTarget: String
    var bundled: Bool
    var adHoc: Bool
    var identifier: String?
    var codeHash: String?
    var pid: Int32

    init(executable: URL, signature: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        var bundle: URL?
        var candidate = executable
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" {
                bundle = candidate
                break
            }
            candidate.deleteLastPathComponent()
        }
        func field(_ name: String) -> String? {
            signature.split(separator: "\n").first { $0.hasPrefix(name) }.map { String($0.dropFirst(name.count)) }
        }
        executablePath = executable.path
        permissionTarget = bundle?.path ?? executable.path
        bundled = bundle != nil
        adHoc = signature.contains("Signature=adhoc") || signature.contains("adhoc,")
        identifier = field("Identifier=")
        codeHash = field("CDHash=")
        self.pid = pid
    }

    /// Reads the running executable's code signature. Slow (spawns `codesign`), so call it off the main actor.
    static func current() -> PermissionRuntime {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", executable.path]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        var signature = ""
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            signature = String(decoding: data, as: UTF8.self)
        }
        return PermissionRuntime(executable: executable.resolvingSymlinksInPath(), signature: signature)
    }
}
