//
//  CSAFEFrame.swift
//  Concept2 SDK
//

import Foundation

/// Builds and reads CSAFE frames: `F1 <contents> <xor checksum> F2`, where a content byte of F0...F3 is
/// sent as `F3` followed by the byte's low two bits.
enum CSAFEFrame {
  static let start: UInt8 = 0xF1
  static let stop: UInt8 = 0xF2
  static let escape: UInt8 = 0xF3

  /// The command wrapper for the PM-specific commands that the Concept2 CSAFE document's examples use.
  static let pmWrapper: UInt8 = 0x1A

  /// The command wrappers whose responses hold more commands' responses.
  private static let wrappers: Set<UInt8> = [0x1A, 0x76, 0x77, 0x7E, 0x7F]

  // MARK: Building
  static func frame(_ contents: [UInt8]) -> Data {
    var bytes: [UInt8] = [start]
    for byte in contents + [contents.reduce(0, ^)] {
      if (0xF0...0xF3).contains(byte) {
        bytes.append(escape)
        bytes.append(byte & 0x03)
      } else {
        bytes.append(byte)
      }
    }
    bytes.append(stop)
    return Data(bytes)
  }

  /// A frame that asks the PM for `commands` inside the PM-specific wrapper. A command is its identifier,
  /// followed, if it takes data, by the number of data bytes and the data.
  static func pmFrame(_ commands: [[UInt8]]) -> Data {
    let inner = commands.flatMap { $0 }
    return frame([pmWrapper, UInt8(inner.count)] + inner)
  }

  // MARK: Reading
  struct Response {
    /// The frame status byte.
    let status: UInt8
    /// The data of each command's response, by command identifier. If a command appears more than once,
    /// the last response is kept.
    let commands: [UInt8: [UInt8]]
  }

  /// Reads one complete frame (`F1 ... F2`). Returns nil if the bytes are not a frame or its checksum is wrong.
  static func parse(_ bytes: [UInt8]) -> Response? {
    guard let first = bytes.firstIndex(of: start),
          let last = bytes[first...].firstIndex(of: stop) else { return nil }
    var contents: [UInt8] = []
    var index = first + 1
    while index < last {
      if bytes[index] == escape, index + 1 < last {
        contents.append(0xF0 | (bytes[index + 1] & 0x03))
        index += 2
      } else {
        contents.append(bytes[index])
        index += 1
      }
    }
    guard contents.count >= 2, let checksum = contents.last else { return nil }
    contents.removeLast()
    guard contents.reduce(0, ^) == checksum else { return nil }
    var commands: [UInt8: [UInt8]] = [:]
    entries(in: contents[1...], into: &commands)
    return Response(status: contents[0], commands: commands)
  }

  /// Reads `identifier, byte count, data` entries; the data of a wrapper holds more entries.
  private static func entries(in bytes: ArraySlice<UInt8>, into commands: inout [UInt8: [UInt8]]) {
    var index = bytes.startIndex
    while index + 1 < bytes.endIndex {
      let identifier = bytes[index]
      let count = Int(bytes[index + 1])
      let dataStart = index + 2
      guard dataStart + count <= bytes.endIndex else { return }
      let data = bytes[dataStart..<dataStart + count]
      if wrappers.contains(identifier) {
        entries(in: data, into: &commands)
      } else {
        commands[identifier] = Array(data)
      }
      index = dataStart + count
    }
  }

  // MARK: Values
  /// A big-endian unsigned value, as the PM sends its multi-byte command responses.
  static func value<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    bytes.reduce(0) { ($0 << 8) | UInt32($1) }
  }
}
