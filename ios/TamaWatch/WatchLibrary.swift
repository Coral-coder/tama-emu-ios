import Foundation

/// A game the phone sent: the dump, its key and the latest save.
struct WatchGame: Codable, Identifiable, Equatable {
  let id: String
  var name: String
  var key: UInt32
  var savedAt: Double // when the save was last written (seconds since 1970)
}

/// The games on the watch: Documents/games/<id>/{dump.bin, game.save, meta.json}.
final class WatchLibrary: ObservableObject {
  static let shared = WatchLibrary()
  @Published private(set) var games: [WatchGame] = []
  @Published var status = ""

  let root: URL = {
    let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("games", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }()

  init() { reload() }

  func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
  func dump(_ id: String) -> URL { dir(id).appendingPathComponent("dump.bin") }
  func save(_ id: String) -> URL { dir(id).appendingPathComponent("game.save") }
  private func meta(_ id: String) -> URL { dir(id).appendingPathComponent("meta.json") }

  func hasDump(_ id: String) -> Bool { FileManager.default.fileExists(atPath: dump(id).path) }

  func reload() {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var out: [WatchGame] = []
    for id in ids {
      guard let d = try? Data(contentsOf: meta(id)), let g = try? JSONDecoder().decode(WatchGame.self, from: d), hasDump(id) else { continue }
      out.append(g)
    }
    DispatchQueue.main.async { self.games = out.sorted { $0.name < $1.name } }
  }

  func store(_ g: WatchGame) {
    try? FileManager.default.createDirectory(at: dir(g.id), withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(g) { try? d.write(to: meta(g.id)) }
    reload()
  }

  func game(_ id: String) -> WatchGame? {
    guard let d = try? Data(contentsOf: meta(id)) else { return nil }
    return try? JSONDecoder().decode(WatchGame.self, from: d)
  }

  /// Puts a received file in place (moved: WatchConnectivity deletes its copy afterwards).
  func receive(file: URL, meta m: [String: Any]) {
    guard let id = m["id"] as? String, let kind = m["kind"] as? String else { return }
    try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
    var g = game(id) ?? WatchGame(id: id, name: m["name"] as? String ?? id, key: 0x5AAF34FB, savedAt: 0)
    if let n = m["name"] as? String { g.name = n }
    if let k = m["key"] as? NSNumber { g.key = k.uint32Value }
    let target = kind == "dump" ? dump(id) : save(id)
    if kind == "save" {
      let stamp = (m["savedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
      // the newer save wins; the one being played here is never overwritten under it
      if stamp < g.savedAt || Console.shared.playing == id { return }
      g.savedAt = stamp
    }
    try? FileManager.default.removeItem(at: target)
    do {
      try FileManager.default.moveItem(at: file, to: target)
    } catch {
      try? FileManager.default.copyItem(at: file, to: target)
    }
    store(g)
    DispatchQueue.main.async { self.status = kind == "dump" ? "\(g.name) arrived" : "Save of \(g.name) updated" }
  }
}
