import CryptoKit
import Foundation
import Security

public enum SigningTrust {
    static func pinnedFingerprint(in bundle: Bundle = .main) throws -> String {
        let resources: Bundle
        if bundle.bundleURL.pathExtension == "app" {
            guard let url = bundle.resourceURL?.appendingPathComponent("terminal-mac_TerminalMacCore.bundle"),
                  let packaged = Bundle(url: url) else { throw Failure("The pinned signing resources are unavailable") }
            resources = packaged
        } else {
            resources = Bundle.module
        }
                guard let url = resources.url(forResource: "SigningFingerprint", withExtension: "txt", subdirectory: "Signing"),
                            let text = try? String(contentsOf: url, encoding: .utf8) else {
                        throw Failure("Signing is not configured; run scripts/configure-signing.sh before building")
        }
                let fingerprint = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard fingerprint.utf8.count == 64,
                            fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                        throw Failure("Invalid pinned signing fingerprint")
                }
                return fingerprint
    }

    public static func verify(_ app: URL, identifier: String) throws {
        guard ["dev.terminal-mac.host", "dev.terminal-mac.guest"].contains(identifier) else { throw Failure("Invalid signing identifier") }
        let expected = try pinnedFingerprint()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("Cannot inspect the app signature: \(app.path)")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw Failure("Invalid app signature or bundle identifier: \(app.path)")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw Failure("The app was not signed with the pinned certificate: \(app.path)")
        }
    }
}