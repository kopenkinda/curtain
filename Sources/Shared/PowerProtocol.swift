import Foundation
import Security
import CryptoKit

@objc(CurtainPowerProtocol) protocol CurtainPowerProtocol {
    func heartbeat(_ active: Bool, batteryLimit: Int, withReply reply: @escaping (Bool, String) -> Void)
}

enum PowerIdentity {
    static let service = "com.dk.curtain.power"
    static let helperPath = "/Library/PrivilegedHelperTools/com.dk.curtain.power"
    static let plistPath = "/Library/LaunchDaemons/com.dk.curtain.power.plist"

    // Both executables use the same persistent local certificate. Pin the leaf,
    // not a bundle identifier another application could copy.
    static func requirement(identifier: String) throws -> String {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { throw failure }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode else { throw failure }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw failure }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
    }

    private static var failure: NSError {
        NSError(domain: "Curtain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Curtain's signing identity could not be verified. Rebuild using scripts/run.sh."])
    }
}
