import Flutter
import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// The app side of the USB serial driver (ios/TamaSerialDriver, DriverKit): lists the adapters the
/// driver has, opens one and passes control transfers and bulk data. Method channel "tama/usbdk",
/// received bytes on the event channel "tama/usbdk/rx". The chip setup (baud rate, line control,
/// DTR/RTS) is done in Dart (lib/services/serial/usb_chips.dart).
final class UsbDriverBridge: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private let ioQueue = DispatchQueue(label: "tama.usbdk.io")
  #if canImport(IOKit)
  private var conn: io_connect_t = 0
  #endif
  private var reading = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let ch = FlutterMethodChannel(name: "tama/usbdk", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    FlutterEventChannel(name: "tama/usbdk/rx", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    #if canImport(IOKit)
    let a = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "supported":
      result(true)
    case "list":
      result(list())
    case "open":
      let id = (a["id"] as? NSNumber)?.uint64Value ?? 0
      ioQueue.async {
        let r = self.open(id)
        DispatchQueue.main.async { result(r) }
      }
    case "control":
      let type = (a["type"] as? Int) ?? 0, req = (a["request"] as? Int) ?? 0
      let value = (a["value"] as? Int) ?? 0, index = (a["index"] as? Int) ?? 0, length = (a["length"] as? Int) ?? 0
      let data = (a["data"] as? FlutterStandardTypedData)?.data
      ioQueue.async {
        let r = self.control(type, req, value, index, length, data)
        DispatchQueue.main.async { result(r) }
      }
    case "write":
      let data = (a["data"] as? FlutterStandardTypedData)?.data ?? Data()
      ioQueue.async {
        let r = self.write(data)
        DispatchQueue.main.async { r == nil ? result(nil) : result(FlutterError(code: "usb", message: r, details: nil)) }
      }
    case "close":
      reading = false
      ioQueue.async {
        self.close()
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
    #else
    if call.method == "supported" { result(false) } else { result(FlutterError(code: "usb", message: "IOKit is not available", details: nil)) }
    #endif
  }

  #if canImport(IOKit)
  private func prop(_ s: io_service_t, _ key: String) -> Any? {
    IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
  }

  private func list() -> [[String: Any]] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("TamaSerialDriver"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [[String: Any]] = []
    while case let s = IOIteratorNext(it), s != 0 {
      var id: UInt64 = 0
      IORegistryEntryGetRegistryEntryID(s, &id)
      let vid = (prop(s, "idVendor") as? NSNumber)?.intValue ?? 0
      let pid = (prop(s, "idProduct") as? NSNumber)?.intValue ?? 0
      let name = (prop(s, "USB Product Name") as? String) ?? (prop(s, "kUSBProductString") as? String) ?? "USB serial"
      out.append(["id": NSNumber(value: id), "name": name, "vid": vid, "pid": pid])
      IOObjectRelease(s)
    }
    return out
  }

  private func open(_ id: UInt64) -> Any {
    close()
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
    guard s != 0 else { return FlutterError(code: "usb", message: "adapter not found", details: nil) }
    defer { IOObjectRelease(s) }
    var c: io_connect_t = 0
    let kr = IOServiceOpen(s, mach_task_self_, 0, &c)
    guard kr == KERN_SUCCESS else {
      return FlutterError(code: "usb", message: "the driver refused (0x\(String(kr, radix: 16))). Allow Tama's driver in Settings → Tama → Drivers.", details: nil)
    }
    var outs = [UInt64](repeating: 0, count: 2)
    var n: UInt32 = 2
    let r = IOConnectCallScalarMethod(c, 0, nil, 0, &outs, &n)
    guard r == KERN_SUCCESS else {
      IOServiceClose(c)
      return FlutterError(code: "usb", message: "could not open the adapter (0x\(String(r, radix: 16)))", details: nil)
    }
    conn = c
    startReading()
    return ["vidPid": NSNumber(value: outs[0]), "interface": NSNumber(value: outs[1])]
  }

  private func control(_ type: Int, _ req: Int, _ value: Int, _ index: Int, _ length: Int, _ data: Data?) -> Any? {
    guard conn != 0 else { return FlutterError(code: "usb", message: "not open", details: nil) }
    var ins: [UInt64] = [UInt64(type), UInt64(req), UInt64(value), UInt64(index), UInt64(length)]
    var outBuf = [UInt8](repeating: 0, count: max(length, 1))
    var outLen = (type & 0x80) != 0 ? length : 0
    let kr: kern_return_t = (data ?? Data()).withUnsafeBytes { p in
      IOConnectCallMethod(conn, 2, &ins, 5, p.baseAddress, (type & 0x80) != 0 ? 0 : (data?.count ?? 0), nil, nil, &outBuf, &outLen)
    }
    guard kr == KERN_SUCCESS else { return FlutterError(code: "usb", message: "control 0x\(String(req, radix: 16)) failed (0x\(String(kr, radix: 16)))", details: nil) }
    return (type & 0x80) != 0 ? FlutterStandardTypedData(bytes: Data(outBuf.prefix(outLen))) : nil
  }

  private func write(_ data: Data) -> String? {
    guard conn != 0 else { return "not open" }
    var off = 0
    while off < data.count {
      let n = min(4096, data.count - off)
      var outs: [UInt64] = [0]
      var on: UInt32 = 1
      let kr: kern_return_t = data.subdata(in: off..<off + n).withUnsafeBytes { p in
        IOConnectCallMethod(conn, 3, nil, 0, p.baseAddress, n, &outs, &on, nil, nil)
      }
      if kr != KERN_SUCCESS { return "write failed (0x\(String(kr, radix: 16)))" }
      off += n
    }
    return nil
  }

  private func startReading() {
    reading = true
    let c = conn
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var buf = [UInt8](repeating: 0, count: 4096)
      while let self = self, self.reading, self.conn == c {
        var ins: [UInt64] = [4096, 20]
        var len = 4096
        let kr = IOConnectCallMethod(c, 4, &ins, 2, nil, 0, nil, nil, &buf, &len)
        if kr != KERN_SUCCESS {
          DispatchQueue.main.async { self.sink?(FlutterError(code: "usb", message: "read stopped (0x\(String(kr, radix: 16)))", details: nil)) }
          break
        }
        if len > 0 {
          let d = Data(buf.prefix(len))
          DispatchQueue.main.async { self.sink?(FlutterStandardTypedData(bytes: d)) }
        }
      }
    }
  }

  private func close() {
    reading = false
    if conn != 0 {
      _ = IOConnectCallScalarMethod(conn, 1, nil, 0, nil, nil)
      IOServiceClose(conn)
      conn = 0
    }
  }
  #endif
}
