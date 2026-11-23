import Foundation
import UserNotifications
import WatchConnectivity
import WatchKit

/// The link with the phone: games and saves come in, saves go back.
final class PhoneLink: NSObject, WCSessionDelegate {
  static let shared = PhoneLink()

  func start() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func sendSave(_ g: WatchGame) {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
    let lib = WatchLibrary.shared
    let src = lib.save(g.id)
    guard FileManager.default.fileExists(atPath: src.path) else { return }
    // a copy: the game may write the save again while it is on its way
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(g.id)-\(Int(g.savedAt)).save")
    try? FileManager.default.removeItem(at: tmp)
    guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return }
    // only the latest save matters
    for t in WCSession.default.outstandingFileTransfers where (t.file.metadata?["id"] as? String) == g.id {
      t.cancel()
    }
    WCSession.default.transferFile(tmp, metadata: ["kind": "save", "id": g.id, "savedAt": g.savedAt])
  }

  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    WatchLibrary.shared.receive(file: file.fileURL, meta: file.metadata ?? [:])
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    calling(message)
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    calling(userInfo)
  }

  /// The pet calls (sent by the phone): a notification with sound, and a tap on the wrist.
  private func calling(_ info: [String: Any]) {
    guard let name = info["call"] as? String else { return }
    // an old call delivered late is not worth a buzz
    if let at = info["at"] as? Double, Date().timeIntervalSince1970 - at > 600 { return }
    DispatchQueue.main.async { WKInterfaceDevice.current().play(.notification) }
    let c = UNMutableNotificationContent()
    c.title = name
    c.body = "Your Tamagotchi is calling you."
    c.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
  }
}
