import AVFoundation
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let tone = TamaTone()
  private var usb: UsbDriverBridge?
  private var watch: WatchBridge?
  private var channel: FlutterMethodChannel?
  /// The game whose notification was tapped, until the app has taken it.
  private var opened: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let r = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    UNUserNotificationCenter.current().delegate = self
    return r
  }

  /// A tap on a call: the app opens on the game that called.
  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
    if let g = response.notification.request.content.userInfo["game"] as? String {
      opened = g
      channel?.invokeMethod("opened", arguments: g)
    }
    completionHandler()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TamaNative") else { return }
    usb = UsbDriverBridge(messenger: registrar.messenger())
    watch = WatchBridge(messenger: registrar.messenger())
    let channel = FlutterMethodChannel(name: "tama/native", binaryMessenger: registrar.messenger())
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "tone":
        let freq = args["freq"] as? Double ?? 4096
        let on = args["on"] as? Bool ?? false
        let vol = args["volume"] as? Double ?? 0.35
        self.tone.set(frequency: freq, on: on, volume: vol)
        result(nil)
      case "toneAt":
        self.tone.schedule(frequency: args["freq"] as? Double ?? 4096, on: args["on"] as? Bool ?? false,
                           volume: args["volume"] as? Double ?? 0.35, delay: Double(args["delay"] as? Int ?? 0) / 1000)
        result(nil)
      case "keepAlive":
        self.tone.keepAlive(args["on"] as? Bool ?? false)
        result(nil)
      case "openSettings":
        // Tama's page in the Settings app (Bluetooth, notifications)
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        result(nil)
      case "keepScreenOn":
        UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
        result(nil)
      case "askToNotify":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        result(nil)
      case "takeOpened":
        result(self.opened)
        self.opened = nil
      case "notify":
        let c = UNMutableNotificationContent()
        if let g = args["game"] as? String { c.userInfo = ["game": g] }
        c.title = args["title"] as? String ?? "Tama"
        c.body = args["body"] as? String ?? ""
        c.sound = .default
        c.threadIdentifier = "tama-calls"
        // the game's screen as it was when the pet called (the system moves the file it is
        // given, so it gets a copy)
        if let path = args["image"] as? String {
          let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("call-\(UUID().uuidString).png")
          if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: tmp)) != nil,
             let a = try? UNNotificationAttachment(identifier: "screen", url: tmp, options: nil) {
            c.attachments = [a]
          }
        }
        let r = UNNotificationRequest(identifier: "tama-call-\(Date().timeIntervalSince1970)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// The toy's buzzer: a square wave from an audio engine. While "keep alive" is on, the engine runs
/// (silent between beeps) with the audio background mode, so the emulator keeps running in the
/// background and the beeps are heard with the phone locked.
final class TamaTone {
  private let engine = AVAudioEngine()
  private var source: AVAudioSourceNode?
  private let lock = NSLock()
  private var freq: Double = 4096
  private var on = false
  private var volume: Float = 0.35
  private var level: Float = 0
  private var phase: Double = 0
  private var sampleRate: Double = 44100
  private var alive = false
  private var observers: [NSObjectProtocol] = []
  /// Changes of the tone to come, in time order: (when, on the system's uptime clock; frequency; on).
  private var queue: [(at: Double, freq: Double, on: Bool)] = []

  /// A change of the tone `delay` seconds from now. The audio thread makes it at the very
  /// sample, so a melody sent ahead of time keeps its rhythm.
  func schedule(frequency: Double, on: Bool, volume: Double, delay: Double) {
    let at = ProcessInfo.processInfo.systemUptime + max(0, delay)
    lock.lock()
    self.volume = Float(max(0, min(1, volume)))
    // what was planned after this moment is replaced by it
    queue.removeAll { $0.at >= at }
    queue.append((at, max(100, frequency), on))
    if queue.count > 64 { queue.removeFirst(queue.count - 64) }
    lock.unlock()
    ensureRunning()
  }

  init() {
    let nc = NotificationCenter.default
    // In the background the buzzer may answer late: the audio hardware is woken in big blocks
    // (a tenth of a second) instead of every few milliseconds.
    observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.1)
    })
    observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.01)
    })
    observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
      guard let self = self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
      self.ensureRunning()
    })
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      self?.ensureRunning()
    })
  }

  func set(frequency: Double, on: Bool, volume: Double) {
    lock.lock()
    self.freq = max(100, frequency)
    self.on = on
    self.volume = Float(max(0, min(1, volume)))
    queue.removeAll()
    lock.unlock()
    if on { ensureRunning() } else if !alive { stopSoon() }
  }

  func keepAlive(_ v: Bool) {
    alive = v
    if v { ensureRunning() } else if !on { stopSoon() }
  }

  private func setUp() {
    if source != nil { return }
    let fmt = engine.outputNode.inputFormat(forBus: 0)
    sampleRate = fmt.sampleRate > 0 ? fmt.sampleRate : 44100
    let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let node = AVAudioSourceNode(format: mono) { [weak self] silence, _, frameCount, abl -> OSStatus in
      guard let self = self else { return noErr }
      // this block of sound starts now; changes that fall into it are made at their sample
      let t0 = ProcessInfo.processInfo.systemUptime
      let span = Double(frameCount) / self.sampleRate
      self.lock.lock()
      var due: [(frame: Int, freq: Double, on: Bool)] = []
      while let e = self.queue.first, e.at < t0 + span {
        due.append((max(0, Int((e.at - t0) * self.sampleRate)), e.freq, e.on))
        self.queue.removeFirst()
      }
      var f = self.freq
      var target: Float = self.on ? self.volume : 0
      let vol = self.volume
      if let last = due.last {
        self.freq = last.freq
        self.on = last.on
      }
      self.lock.unlock()
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
      if !due.isEmpty {
        var next = 0
        var step = f / self.sampleRate
        for frame in 0..<Int(frameCount) {
          while next < due.count && due[next].frame <= frame {
            f = due[next].freq
            target = due[next].on ? vol : 0
            step = f / self.sampleRate
            next += 1
          }
          self.level += (target - self.level) * 0.01
          self.phase += step
          if self.phase >= 1 { self.phase -= 1 }
          let v: Float = (self.phase < 0.5 ? 1 : -1) * self.level * 0.5
          for b in buffers {
            b.mData?.assumingMemoryBound(to: Float.self)[frame] = v
          }
        }
        return noErr
      }
      // Between beeps (nearly all the time in the background): zeros, flagged as silence so the
      // system does no mixing work, and no per-sample maths.
      if target == 0 && abs(self.level) < 0.0005 {
        self.level = 0
        for b in buffers {
          if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
        }
        silence.pointee = true
        return noErr
      }
      let step = f / self.sampleRate
      for frame in 0..<Int(frameCount) {
        // a short ramp so on/off do not click
        self.level += (target - self.level) * 0.01
        self.phase += step
        if self.phase >= 1 { self.phase -= 1 }
        let v: Float = (self.phase < 0.5 ? 1 : -1) * self.level * 0.5
        for b in buffers {
          b.mData?.assumingMemoryBound(to: Float.self)[frame] = v
        }
      }
      return noErr
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: mono)
    source = node
  }

  private func ensureRunning() {
    do {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try s.setActive(true)
      setUp()
      if !engine.isRunning { try engine.start() }
    } catch {
      NSLog("TamaTone: \(error)")
    }
  }

  private func stopSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self = self, !self.alive, !self.on else { return }
      self.engine.pause()
    }
  }
}
