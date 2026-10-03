//
//  RowingForceCurvePacket.swift
//
//  One notification of the Force Curve Data characteristic (0x003D). A stroke's curve is split
//  across several of these.
//

import Foundation

struct RowingForceCurvePacket: CharacteristicModel {
  /*
    Byte 0: MS nibble = total number of packets for this curve,
            LS nibble = number of 16-bit points in this packet
    Byte 1: sequence number (0-based)
    Bytes 2...: points, 16 bit little-endian
  */
  var totalPackets = 0
  var sequence = 0
  var points = [Int]()

  init(fromData data: Data) {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { return }

    totalPackets = Int(bytes[0] >> 4)
    let pointCount = Int(bytes[0] & 0x0F)
    sequence = Int(bytes[1])

    var i = 0
    while i < pointCount && 3 + 2 * i < bytes.count {
      points.append(Int(bytes[2 + 2 * i]) | (Int(bytes[3 + 2 * i]) << 8))
      i += 1
    }
  }

  // MARK: PerformanceMonitor
  func updatePerformanceMonitor(performanceMonitor:PerformanceMonitor) {
    performanceMonitor.addForceCurvePacket(self)
  }
}
