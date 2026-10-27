//
//  USBManager.swift
//  Concept2 SDK
//

#if os(macOS)
import Foundation
import IOKit.hid

/// Finds PM5s on USB cables and connects to them, the way `BluetoothManager` does over Bluetooth. A PM5 is
/// listed as soon as its cable is plugged in and removed when it is pulled out.
public final class USBManager {
  public static let sharedInstance = USBManager()

  /// The PM5s on USB cables.
  public static var performanceMonitors: Subject<[PerformanceMonitor]> {
    return sharedInstance.performanceMonitors
  }

  public static func connectPerformanceMonitor(performanceMonitor: PerformanceMonitor) {
    sharedInstance.queue.async { sharedInstance.connect(performanceMonitor) }
  }

  public static func disconnectPerformanceMonitor(performanceMonitor: PerformanceMonitor) {
    sharedInstance.queue.async { sharedInstance.disconnect(performanceMonitor) }
  }

  private static let concept2VendorID = 0x17A4

  private let performanceMonitors = Subject<[PerformanceMonitor]>(value: [])
  private let queue = DispatchQueue(label: "com.boutfitness.concept2.usb")
  private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
  private var entries: [(device: IOHIDDevice, monitor: PerformanceMonitor)] = []

  private init() {
    let matching: [String: Any] = [kIOHIDVendorIDKey: Self.concept2VendorID]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
      guard let context else { return }
      Unmanaged<USBManager>.fromOpaque(context).takeUnretainedValue().added(device)
    }, context)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
      guard let context else { return }
      Unmanaged<USBManager>.fromOpaque(context).takeUnretainedValue().removed(device)
    }, context)
    IOHIDManagerSetDispatchQueue(manager, queue)
    IOHIDManagerActivate(manager)
  }

  // MARK: Devices
  private func string(_ device: IOHIDDevice, _ key: String) -> String? {
    return IOHIDDeviceGetProperty(device, key as CFString) as? String
  }

  private func added(_ device: IOHIDDevice) {
    guard let product = string(device, kIOHIDProductKey), product.contains("Performance Monitor") else { return }
    let serial = string(device, kIOHIDSerialNumberKey)
    let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int).map { String($0, radix: 16) }
    let identifier = "usb-" + (serial ?? location ?? product)
    guard !entries.contains(where: { $0.monitor.usbIdentifier == identifier }) else { return }
    let name = serial.map { "\(Self.shortName(product)) \($0)" } ?? Self.shortName(product)
    entries.append((device, PerformanceMonitor(usbName: name, usbIdentifier: identifier)))
    publish()
  }

  /// "Concept2 Performance Monitor 5 (PM5)" as "PM5".
  private static func shortName(_ product: String) -> String {
    if let open = product.lastIndex(of: "("), let close = product.lastIndex(of: ")"), open < close {
      return String(product[product.index(after: open)..<close])
    }
    return product
  }

  private func removed(_ device: IOHIDDevice) {
    guard let index = entries.firstIndex(where: { CFEqual($0.device, device) }) else { return }
    let monitor = entries[index].monitor
    disconnect(monitor)
    entries.remove(at: index)
    publish()
  }

  private func publish() {
    let monitors = entries.map { $0.monitor }
    DispatchQueue.main.async { [self] in performanceMonitors.value = monitors }
  }

  private func stateChanged(_ monitor: PerformanceMonitor) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: PerformanceMonitor.DidUpdateStateNotification, object: monitor)
    }
  }

  // MARK: Connecting
  private func connect(_ monitor: PerformanceMonitor) {
    guard !monitor.usbConnected, let entry = entries.first(where: { $0.monitor === monitor }) else { return }
    guard let transport = USBTransport(device: entry.device, queue: queue) else { return }
    let poller = USBPoller(monitor: monitor, transport: transport, queue: queue)
    guard poller.start() else { return }
    monitor.usbPoller = poller
    monitor.usbConnected = true
    stateChanged(monitor)
  }

  private func disconnect(_ monitor: PerformanceMonitor) {
    guard monitor.usbConnected || monitor.usbPoller != nil else { return }
    monitor.usbPoller?.stop()
    monitor.usbPoller = nil
    monitor.usbConnected = false
    stateChanged(monitor)
  }
}
#endif
