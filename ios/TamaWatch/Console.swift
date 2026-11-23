import AVFoundation
import Foundation
import WatchKit

/// The running Paradise on the watch: the native core (same as the phone's) paced to real time.
final class Console: ObservableObject {
  static let shared = Console()

  @Published private(set) var image: CGImage?
  @Published private(set) var playing: String?
  @Published private(set) var speed: Double = 0
  @Published var error: String?

  private var t: OpaquePointer?
  // The console runs on a thread of its own, flat out (the watch's processor is the limit), and
  // the screen gets finished pictures; every call into the core goes through this lock.
  private let core = NSLock()
  private let emu = DispatchQueue(label: "tama.watch.emu", qos: .userInteractive)
  private var looping = false
  private var due: Double = 0
  private var owed: Double = 0  // seconds the clock still owes (time that could not be run)
  private var last = Date()
  private var lastSave = Date()
  private var lastPicture = Date.distantPast
  private var awayAt: Date?
  private var quietSince = Date.distantPast
  private let fb = UnsafeMutablePointer<UInt16>.allocate(capacity: 128 * 128)
  private var rgba = [UInt8](repeating: 255, count: 128 * 128 * 4)
  private let tone = WatchTone()
  private let cps = Double(tama_cycles_per_second())

  private func withCore<R>(_ f: (OpaquePointer) -> R) -> R? {
    core.lock()
    defer { core.unlock() }
    guard let t = t else { return nil }
    return f(t)
  }

  static let pinA: UInt32 = 0x09, pinB: UInt32 = 0x0B, pinC: UInt32 = 0x0A, pinWheel: UInt32 = 0x08
  static let enc1: UInt32 = 0x20, enc2: UInt32 = 0x21

  func play(_ g: WatchGame) {
    stop()
    let lib = WatchLibrary.shared
    // the watch only carries on games set up on the phone
    guard let size = try? FileManager.default.attributesOfItem(atPath: lib.save(g.id).path)[.size] as? NSNumber, size.intValue > 0 else {
      error = "Start this game on your iPhone first, then send it to the watch."
      return
    }
    guard let t = tama_new() else { return }
    let r = tama_load(t, lib.dump(g.id).path, g.key, 1)
    if r != 1 {
      tama_free(t)
      error = r == 0 ? "The firmware stays locked (wrong key)." : "The dump could not be loaded."
      return
    }
    tama_open_save(t, lib.save(g.id).path)
    tama_sync_clock(t, Console.localSeconds())
    tama_auto_date(t, 180)
    tama_auto_care(t, g.care ?? 0)
    core.lock()
    self.t = t
    core.unlock()
    playing = g.id
    UserDefaults.standard.set(g.id, forKey: "lastGame")
    error = nil
    start()
  }

  /// Local time in seconds since 2025-01-01, the firmware's epoch.
  static func localSeconds() -> UInt64 {
    let now = Date()
    let local = now.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: now)) - 1_735_689_600
    return UInt64(max(0, local))
  }

  private func start() {
    guard !looping, t != nil else { return }
    looping = true
    last = Date()
    due = 0
    emu.async { [weak self] in self?.loop() }
  }

  private func pause() {
    looping = false
    wake.signal()
    emu.sync {}  // the loop has stopped
    tone.set(0)
  }

  private func loop() {
    while looping {
      let behind = step()
      // while the console sleeps (its screen off) a tenth of a second between looks is plenty;
      // a key or the crown cuts the wait short
      if !behind { wake.wait(timeout: .now() + (asleep ? 0.1 : 0.004)) }
    }
  }
  private let wake = DispatchSemaphore(value: 0)
  private var asleep = false
  private func nudge() {
    if asleep { wake.signal() }
  }

  /// One slice of the console. True when it is behind real time (run again at once).
  private func step() -> Bool {
    core.lock()
    guard let t = t else {
      core.unlock()
      return false
    }
    let now = Date()
    var dt = now.timeIntervalSince(last)
    last = now
    if dt > 2 {
      tama_advance(t, UInt32(dt))
      dt -= floor(dt)
    }
    due += cps * dt
    // what the watch cannot run in time is skipped by the clock (the pet's time stays right)
    let cap = cps * 0.25
    if due > cap {
      owed += (due - cap) / cps
      due = cap
      if owed >= 1 {
        tama_advance(t, UInt32(owed))
        owed -= floor(owed)
      }
    }
    let want = UInt64(max(0, due))
    let done = want > 0 ? tama_run(t, want, 30) : 0
    due -= Double(done)
    let changed = tama_screen(t, fb) != 0
    let note = tama_note(t)
    let stopped = tama_running(t) == 0
    asleep = tama_idle_seconds(t) > 0
    core.unlock()

    let ratio = dt > 0 ? min(1, Double(done) / (cps * dt)) : 1
    // the picture, at most 20 times a second
    if changed && now.timeIntervalSince(lastPicture) > 0.05 {
      lastPicture = now
      let img = picture()
      DispatchQueue.main.async { [weak self] in
        self?.image = img
        self?.speed = (self?.speed ?? 0) * 0.8 + 0.2 * ratio
      }
    }
    tone.set(note)
    if note > 0 {
      if now.timeIntervalSince(quietSince) > 3 { DispatchQueue.main.async { WKInterfaceDevice.current().play(.notification) } }
      quietSince = .distantFuture
    } else if quietSince == .distantFuture {
      quietSince = now
    }
    if now.timeIntervalSince(lastSave) > 60 {
      lastSave = now
      DispatchQueue.main.async { [weak self] in self?.saveNow(send: false) }
    }
    if stopped {
      looping = false
      DispatchQueue.main.async { [weak self] in self?.error = "The console stopped." }
    }
    return due > cps * 0.02
  }

  private func picture() -> CGImage? {
    for i in 0..<(128 * 128) {
      let v = fb[i]
      rgba[i * 4] = UInt8((Int(v >> 11) & 31) * 255 / 31)
      rgba[i * 4 + 1] = UInt8((Int(v >> 5) & 63) * 255 / 63)
      rgba[i * 4 + 2] = UInt8((Int(v) & 31) * 255 / 31)
    }
    let data = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// Leaves the game: saved here and sent to the phone.
  func stop() {
    pause()
    guard t != nil else { return }
    saveNow(send: true)
    core.lock()
    if let t = t { tama_free(t) }
    t = nil
    core.unlock()
    playing = nil
    image = nil
  }

  /// The watch app goes to the background (wrist down) or comes back: the save goes to the phone,
  /// and on return the console's clock catches up with the time away.
  func scene(active: Bool) {
    guard t != nil else { return }
    if active {
      if let a = awayAt {
        let s = Date().timeIntervalSince(a)
        if s > 2 { _ = withCore { tama_advance($0, UInt32(min(s, Double(UInt32.max)))) } }
      }
      awayAt = nil
      start()
    } else {
      if awayAt == nil { awayAt = Date() }
      releaseAll()
      pause()
      saveNow(send: true)
    }
  }

  private func saveNow(send: Bool) {
    guard let id = playing else { return }
    lastSave = Date()
    if (withCore { tama_write_save($0) } ?? -1) >= 0, var g = WatchLibrary.shared.game(id) {
      g.savedAt = Date().timeIntervalSince1970
      WatchLibrary.shared.store(g)
      if send { PhoneLink.shared.sendSave(g) }
    }
  }

  func press(_ pin: UInt32) {
    WKInterfaceDevice.current().play(.click)
    _ = withCore { tama_press($0, pin) }
    nudge()
  }

  func release(_ pin: UInt32) {
    _ = withCore { tama_release($0, pin) }
  }

  /// Feeds (1), plays (2), cures (4). False: no pet found.
  func care(_ what: UInt32) -> Bool {
    return withCore { tama_care($0, what) } == 1
  }

  /// The reset button on the back of the toy (the save stays).
  func reset() {
    saveNow(send: false)
    _ = withCore { t -> Void in
      tama_reset(t)
      if tama_sync_clock(t, Console.localSeconds()) > 0 { tama_auto_date(t, 180) }
    }
  }

  func releaseAll() {
    _ = withCore { tama_release_all($0) }
  }

  /// One detent of the crown: a step of the wheel, played by the core in console time.
  func turn(_ right: Bool) {
    _ = withCore { tama_turn($0, right ? 1 : 0) }
    nudge()
  }
}

/// The toy's buzzer: a square wave.
final class WatchTone {
  private let engine = AVAudioEngine()
  private var node: AVAudioSourceNode?
  private let lock = NSLock()
  private var freq: Double = 0
  private var level: Float = 0
  private var phase: Double = 0
  private var started = false

  func set(_ hz: Float) {
    lock.lock()
    freq = Double(hz)
    lock.unlock()
    // started but not running (the route was not ready, an interruption): try again
    if hz > 20 && (!started || !engine.isRunning) { begin() }
  }

  private func begin() {
    started = true
    // Every step can fail on the watch (no route, a format the hardware does not take): then the
    // game simply stays silent, it must never take the app down.
    // .playback, not .ambient: ambient sound is muted by the watch's Silent Mode, and the toy's
    // buzzer is the point (mixed with other audio, not stopping it).
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      return
    }
    if engine.isRunning { return }
    if let n = node {
      // a second try after a failed start: the source is already attached
      engine.prepare()
      try? engine.start()
      _ = n
      return
    }
    let out = engine.mainMixerNode.outputFormat(forBus: 0)
    let rate = out.sampleRate > 8000 ? out.sampleRate : 44100
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
    let n = AVAudioSourceNode(format: fmt) { [weak self] _, _, count, abl -> OSStatus in
      guard let self = self else { return noErr }
      self.lock.lock()
      let f = self.freq
      self.lock.unlock()
      let target: Float = f > 20 ? 0.8 : 0
      let bufs = UnsafeMutableAudioBufferListPointer(abl)
      for i in 0..<Int(count) {
        self.level += (target - self.level) * 0.01
        if f > 20 {
          self.phase += f / rate
          if self.phase >= 1 { self.phase -= 1 }
        }
        let v: Float = (self.phase < 0.5 ? 1 : -1) * self.level * 0.5
        for b in bufs {
          guard let p = b.mData else { continue }
          let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size
          if i < frames { p.assumingMemoryBound(to: Float.self)[i] = v }
        }
      }
      return noErr
    }
    engine.attach(n)
    engine.connect(n, to: engine.mainMixerNode, format: fmt)
    node = n
    engine.prepare()
    do {
      try engine.start()
    } catch {
      engine.detach(n)
      node = nil
    }
  }
}
