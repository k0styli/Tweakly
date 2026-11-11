import CryptoKit
import FanControlCore
import Foundation
import Security
import os

private let log = Logger(subsystem: "me.tweakly.Tweakly.fanhelper", category: "start")

/// The helper is installed for one copy of the app, named by the root-owned launchd file that starts it, and it answers
/// only what is signed the way it is. Signed with Developer ID, that is any Developer ID signature of the same team, so a
/// renewed certificate keeps working. Signed with the local certificate of a development Mac, it is that certificate.
/// With no certificate of its own it answers nobody.
private func clientRequirement(bundleID: String) -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
        let information = information as? [String: Any],
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
        let leaf = certificates.first
    else { return nil }
    // Apple's own fields for a Developer ID intermediate and leaf, as in the designated requirement codesign writes.
    if let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
        return """
            identifier "\(bundleID)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\(team)"
            """
    }
    let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }
        .joined()
    return "identifier \"\(bundleID)\" and certificate leaf = H\"\(hash)\""
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let service = FanService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = service
        let service = service
        connection.invalidationHandler = { [weak connection] in
            if let connection { service.connectionEnded(connection) }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: FanHelper.clientArgument), flag + 1 < arguments.count else {
    log.error("Started without the app it belongs to")
    exit(64)
}
let bundleID = arguments[flag + 1]
guard let requirement = clientRequirement(bundleID: bundleID) else {
    log.error("Not signed with a certificate, so it cannot tell who is asking")
    exit(78)
}
private let delegate = Listener()
let listener = NSXPCListener(machServiceName: FanHelper.label(forApp: bundleID))
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
