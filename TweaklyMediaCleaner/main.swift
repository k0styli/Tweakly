import Foundation
import LiveWallpaperCore

/// The only code in Tweakly that reads a picture or video from outside: downloads and files someone adds. It runs in
/// the App Sandbox with no network and no files but the inbox (`Config/TweaklyMediaCleaner.entitlements`), so a file
/// made to attack a decoder can at most take down this process. What it hands back is written anew by it: a picture's
/// pixels as PNG, a video's frames in a container of its own.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// launchd starts an XPC service for the app that holds it in its bundle and no other, so only Tweakly connects.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MediaCleaning.self)
        connection.exportedObject = CleanerService()
        connection.resume()
        return true
    }
}

final class CleanerService: NSObject, MediaCleaning {
    func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task.detached(priority: .utility) {
            let answer = await MediaCleaner.clean(request)
            reply((try? JSONEncoder().encode(answer)) ?? Data())
        }
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
