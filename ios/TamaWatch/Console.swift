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
  private var timer: Timer?
  private var due: Double = 0
  private var last = Date()
  private var lastSave = Date()
  private var awayAt: Date?
  private var quietSince = Date.distantPast
  private let fb = UnsafeMutablePointer<UInt16>.allocate(capacity: 128 * 128)
  private var rgba = [UInt8](repeating: 255, count: 128 * 128 * 4)
  private let tone = WatchTone()
  private let cps = Double(tama_cycles_per_second())

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
    self.t = t
    playing = g.id
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
    guard timer == nil, t != nil else { return }
    last = Date()
    due = 0
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.frame() }
  }

  private func pause() {
    timer?.invalidate()
    timer = nil
    tone.set(0)
  }

  /// Leaves the game: saved here and sent to the phone.
  func stop() {
    pause()
    guard let t = t else { return }
    saveNow(send: true)
    tama_free(t)
    self.t = nil
    playing = nil
    image = nil
  }

  /// The watch app goes to the background (wrist down) or comes back: the save goes to the phone,
  /// and on return the console's clock catches up with the time away.
  func scene(active: Bool) {
    guard let t = t else { return }
    if active {
      if let a = awayAt {
        let s = Date().timeIntervalSince(a)
        if s > 2 { tama_advance(t, UInt32(min(s, Double(UInt32.max)))) }
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

  private func frame() {
    guard let t = t else { return }
    let now = Date()
    var dt = now.timeIntervalSince(last)
    last = now
    if dt > 2 {
      tama_advance(t, UInt32(dt))
      dt -= floor(dt)
    }
    due += cps * dt
    if due > cps * 0.25 { due = cps * 0.25 }
    let want = UInt64(max(0, due))
    let done = want > 0 ? tama_run(t, want, 22) : 0
    due -= Double(done)
    if dt > 0 { speed = speed * 0.9 + 0.1 * min(1, Double(done) / (cps * dt)) }
    if tama_screen(t, fb) != 0 { draw() }
    let note = tama_note(t)
    tone.set(note)
    // every sound taps the wrist (one tap per melody: after 3 s of quiet)
    if note > 0 {
      if now.timeIntervalSince(quietSince) > 3 { WKInterfaceDevice.current().play(.notification) }
      quietSince = .distantFuture
    } else if quietSince == .distantFuture {
      quietSince = now
    }
    // the console's screen stays on while the game is shown
    if tama_sleeping(t) != 0 { tama_wake(t) }
    if now.timeIntervalSince(lastSave) > 60 { saveNow(send: false) }
    if tama_running(t) == 0 {
      error = "The console stopped."
      pause()
    }
  }

  private func draw() {
    for i in 0..<(128 * 128) {
      let v = fb[i]
      rgba[i * 4] = UInt8((Int(v >> 11) & 31) * 255 / 31)
      rgba[i * 4 + 1] = UInt8((Int(v >> 5) & 63) * 255 / 63)
      rgba[i * 4 + 2] = UInt8((Int(v) & 31) * 255 / 31)
    }
    let data = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: data) else { return }
    image = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  private func saveNow(send: Bool) {
    guard let t = t, let id = playing else { return }
    lastSave = Date()
    if tama_write_save(t) >= 0, var g = WatchLibrary.shared.game(id) {
      g.savedAt = Date().timeIntervalSince1970
      WatchLibrary.shared.store(g)
      if send { PhoneLink.shared.sendSave(g) }
    }
  }

  func press(_ pin: UInt32) {
    guard let t = t else { return }
    WKInterfaceDevice.current().play(.click)
    tama_press(t, pin)
  }

  func release(_ pin: UInt32) {
    guard let t = t else { return }
    tama_release(t, pin)
  }

  /// Feeds (1), plays (2), cures (4). False: no pet found.
  func care(_ what: UInt32) -> Bool {
    guard let t = t else { return false }
    return tama_care(t, what) == 1
  }

  /// The reset button on the back of the toy (the save stays).
  func reset() {
    guard let t = t else { return }
    saveNow(send: false)
    tama_reset(t)
    if tama_sync_clock(t, Console.localSeconds()) > 0 { tama_auto_date(t, 180) }
  }

  func releaseAll() {
    guard let t = t else { return }
    tama_release_all(t)
  }

  /// One detent of the crown: a step of the wheel, played by the core in console time.
  func turn(_ right: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let t = self?.t else { return }
      tama_turn(t, right ? 1 : 0)
    }
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
    if hz > 20 && !started { begin() }
  }

  private func begin() {
    started = true
    // Every step can fail on the watch (no route, a format the hardware does not take): then the
    // game simply stays silent, it must never take the app down.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.ambient, mode: .default)
      try session.setActive(true)
    } catch {
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
      let target: Float = f > 20 ? 0.3 : 0
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
