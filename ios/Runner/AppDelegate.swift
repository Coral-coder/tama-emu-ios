import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let tone = TamaTone()
  private var usb: UsbDriverBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TamaNative") else { return }
    usb = UsbDriverBridge(messenger: registrar.messenger())
    let channel = FlutterMethodChannel(name: "tama/native", binaryMessenger: registrar.messenger())
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
      case "keepAlive":
        self.tone.keepAlive(args["on"] as? Bool ?? false)
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

  init() {
    let nc = NotificationCenter.default
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
    let node = AVAudioSourceNode(format: mono) { [weak self] _, _, frameCount, abl -> OSStatus in
      guard let self = self else { return noErr }
      self.lock.lock()
      let f = self.freq, target: Float = self.on ? self.volume : 0
      self.lock.unlock()
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
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
