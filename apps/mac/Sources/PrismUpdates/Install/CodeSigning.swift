import Foundation
import Security

/// Keeps an update from replacing the identity to which macOS granted access. Ported from
/// `update_signature.rs`, using the Security framework instead of running `codesign`.
protocol CodeSigningVerifier: Sendable {
    /// Throws unless `candidate` is validly signed by a certificate for the same app as `installed`, and each
    /// bundle satisfies the other's designated requirement.
    func verifyCompatible(candidate: URL, installed: URL) throws
}

struct CodeSigningIdentity: Equatable {
    var identifier: String?
    var isAdHoc: Bool
    /// Whether the signature carries a certificate chain ("Authority=" in `codesign -dv`).
    var hasCertificate: Bool
    var designatedRequirement: String?
}

enum CodeSigningFailure: Error, Equatable {
    case identityChanged
}

enum CodeSigning {
    /// The designated requirement to compare against, or a failure for an ad-hoc signature, another app or a
    /// requirement pinned to one build's hash. Same rules as `requirement_from` in `update_signature.rs`.
    static func requirement(of identity: CodeSigningIdentity, expectedIdentifier: String) throws(CodeSigningFailure) -> String {
        guard identity.identifier == expectedIdentifier, !identity.isAdHoc, identity.hasCertificate,
              let requirement = identity.designatedRequirement,
              !requirement.contains("cdhash"), requirement.contains("identifier \"\(expectedIdentifier)\"")
        else { throw .identityChanged }
        return requirement
    }
}

/// Checks real bundles with `SecStaticCode`: strict validation of every architecture and nested code (the
/// equivalent of `codesign --verify --deep --strict --all-architectures`), then the mutual requirement check.
struct SecurityCodeSigningVerifier: CodeSigningVerifier {
    var expectedIdentifier: String

    private static let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)

    func verifyCompatible(candidate: URL, installed: URL) throws {
        let installedCode = try Self.staticCode(installed)
        let candidateCode = try Self.staticCode(candidate)
        let previous = try CodeSigning.requirement(of: Self.identity(installedCode), expectedIdentifier: expectedIdentifier)
        let next = try CodeSigning.requirement(of: Self.identity(candidateCode), expectedIdentifier: expectedIdentifier)
        try Self.check(candidateCode, satisfies: previous)
        try Self.check(installedCode, satisfies: next)
    }

    static func staticCode(_ url: URL) throws(CodeSigningFailure) -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        else { throw .identityChanged }
        return code
    }

    static func identity(_ code: SecStaticCode) throws(CodeSigningFailure) -> CodeSigningIdentity {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { throw .identityChanged }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []

        var requirement: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement {
            _ = SecRequirementCopyString(requirement, [], &text)
        }
        return CodeSigningIdentity(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            hasCertificate: !certificates.isEmpty,
            designatedRequirement: text as String?
        )
    }

    private static func check(_ code: SecStaticCode, satisfies source: String) throws(CodeSigningFailure) {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw .identityChanged }
    }
}
