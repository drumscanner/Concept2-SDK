//
//  USBTransport.swift
//  Concept2 SDK
//

#if os(macOS)
import Foundation
import IOKit.hid

/// One PM5 on a USB cable. The PM5 appears as a HID device; each CSAFE frame goes in one report whose
/// first byte is the report ID: 1 for a frame of up to 20 bytes, 2 for one of up to 120.
@available(macOS 10.15, *)
final class USBTransport {
  let device: IOHIDDevice
  private let queue: DispatchQueue
  /// A complete frame as the PM5 sent it, and when it arrived.
  var onFrame: (([UInt8], Date) -> Void)?
  private(set) var isOpen = false

  private static let inputSize = 512
  private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: USBTransport.inputSize)

  /// The manager's own device object is already scheduled and active, and registering a callback on it
  /// ends the process; so a separate one is made for the same IOService.
  init?(device managed: IOHIDDevice, queue: DispatchQueue) {
    guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(managed)) else { return nil }
    self.device = device
    self.queue = queue
  }

  deinit {
    input.deallocate()
  }

  /// The size of each report the PM5 takes (output) and sends (input), report ID included, read from the
  /// device's HID report descriptor.
  private(set) lazy var outputSizes: [UInt8: Int] = reportSizes(output: true)
  private(set) lazy var inputSizes: [UInt8: Int] = reportSizes(output: false)

  private func reportSizes(output: Bool) -> [UInt8: Int] {
    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return [:] }
    var bits: [UInt32: Int] = [:]
    for element in elements {
      let type = IOHIDElementGetType(element)
      guard output ? type == kIOHIDElementTypeOutput : (type.rawValue >= 1 && type.rawValue <= 4) else { continue }
      // The device lists one element per item of an array, each with the array's count, so only the item's size adds up.
      bits[IOHIDElementGetReportID(element), default: 0] += Int(IOHIDElementGetReportSize(element))
    }
    return Dictionary(uniqueKeysWithValues: bits.map { (UInt8(clamping: $0.key), $0.value / 8 + 1) })
  }

  var reportDescription: String {
    func list(_ sizes: [UInt8: Int]) -> String { sizes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
    return "out " + list(outputSizes) + " in " + list(inputSizes)
  }

  func open() -> Bool {
    guard !isOpen, IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return isOpen }
    // The device calls back until its cancel handler has run, so it keeps this object alive until then.
    let context = Unmanaged.passRetained(self).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(device, input, Self.inputSize, { context, _, _, _, _, report, length in
      guard let context else { return }
      let transport = Unmanaged<USBTransport>.fromOpaque(context).takeUnretainedValue()
      transport.onFrame?(Array(UnsafeBufferPointer(start: report, count: length)), Date())
    }, context)
    IOHIDDeviceSetCancelHandler(device) { Unmanaged<USBTransport>.fromOpaque(context).release() }
    IOHIDDeviceSetDispatchQueue(device, queue)
    IOHIDDeviceActivate(device)
    isOpen = true
    return true
  }

  func close() {
    guard isOpen else { return }
    isOpen = false
    onFrame = nil
    // A callback can't be changed once the device is active, so it is cancelled instead.
    IOHIDDeviceCancel(device)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  /// Sends a CSAFE frame in a report of the given ID, or of the smallest ID it fits: 1 holds 20 bytes, 4 holds
  /// 62 (500 in newer firmware) and 2 holds 120. Returns false if it is too long or the PM5 doesn't take it.
  func send(_ frame: Data, reportID: UInt8? = nil) -> Bool {
    guard isOpen else { return false }
    let id = reportID ?? (frame.count <= 20 ? 1 : (frame.count <= 62 ? 4 : 2))
    let defaults: [UInt8: Int] = [1: 21, 2: 121, 4: 501]
    // A size that isn't plausible for a report (the descriptor was misread) is replaced by the document's.
    let described = outputSizes[id].flatMap { $0 <= 1024 ? $0 : nil }
    guard let size = described ?? defaults[id], frame.count < size else { return false }
    var report = [UInt8](repeating: 0, count: size)
    report[0] = id
    report.replaceSubrange(1..<1 + frame.count, with: frame)
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), report, report.count) == kIOReturnSuccess
  }
}
#endif
