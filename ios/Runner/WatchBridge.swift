import Flutter
import Foundation
import WatchConnectivity

/// The phone side of the Apple Watch link (channel tama/watch): sends a game (its dump, key and
/// save) to the watch, and hands saves coming back from the watch to the app.
final class WatchBridge: NSObject, WCSessionDelegate {
  private let channel: FlutterMethodChannel
  private let inbox: URL
  private var pending: [[String: Any]] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tama/watch", binaryMessenger: messenger)
    inbox = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("watch-inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      guard WCSession.isSupported() else { return result(["supported": false]) }
      let s = WCSession.default
      result(["supported": true, "paired": s.isPaired, "installed": s.isWatchAppInstalled, "reachable": s.isReachable])
    case "send":
      guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
        return result(FlutterError(code: "watch", message: "The Apple Watch link is not ready.", details: nil))
      }
      guard WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
        return result(FlutterError(code: "watch", message: "Install Tama on your Apple Watch first (Watch app on the iPhone → Available apps).", details: nil))
      }
      let id = args["id"] as? String ?? ""
      var meta: [String: Any] = ["last": args["last"] as? Bool ?? false, "id": id, "name": args["name"] as? String ?? id, "key": args["key"] as? NSNumber ?? 0x5AAF34FB, "care": args["care"] as? NSNumber ?? 0]
      if (args["sendDump"] as? Bool) ?? true, let dump = args["dump"] as? String {
        meta["kind"] = "dump"
        WCSession.default.transferFile(URL(fileURLWithPath: dump), metadata: meta)
      }
      if let save = args["save"] as? String, FileManager.default.fileExists(atPath: save) {
        // a copy: the save on the phone may change while it travels
        let tmp = inbox.appendingPathComponent("out-\(id)-\(Int(Date().timeIntervalSince1970)).save")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: save), to: tmp)
        meta["kind"] = "save"
        meta["savedAt"] = Date().timeIntervalSince1970
        for t in WCSession.default.outstandingFileTransfers where (t.file.metadata?["id"] as? String) == id && (t.file.metadata?["kind"] as? String) == "save" {
          t.cancel()
        }
        WCSession.default.transferFile(tmp, metadata: meta)
      }
      result(nil)
    case "call":
      // the pet calls: a live message when the watch app is reachable, else queued user info
      // (delivered when the watch can take it); the watch pops a notification with sound
      guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled else { return result(nil) }
      let info: [String: Any] = ["call": args["name"] as? String ?? "Tama", "at": Date().timeIntervalSince1970]
      if WCSession.default.isReachable {
        WCSession.default.sendMessage(info, replyHandler: nil) { _ in WCSession.default.transferUserInfo(info) }
      } else {
        WCSession.default.transferUserInfo(info)
      }
      result(nil)
    case "pending":
      // saves that came from the watch while the app was not listening
      let p = pending
      pending.removeAll()
      result(p)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    let m = file.metadata ?? [:]
    guard (m["kind"] as? String) == "save", let id = m["id"] as? String else { return }
    let dest = inbox.appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970 * 1000)).save")
    do {
      try FileManager.default.moveItem(at: file.fileURL, to: dest)
    } catch {
      try? FileManager.default.copyItem(at: file.fileURL, to: dest)
    }
    let item: [String: Any] = ["id": id, "path": dest.path, "savedAt": m["savedAt"] ?? 0]
    DispatchQueue.main.async {
      self.channel.invokeMethod("save", arguments: item) { r in
        // nobody listening yet (the app is starting): kept for "pending"
        if r is FlutterError || (r as? NSObject) == FlutterMethodNotImplemented { self.pending.append(item) }
      }
    }
  }
}
