//
//  PerformanceMonitor.swift
//  Pods
//
//  Created by Jesse Curry on 9/27/15.
//  Copyright © 2015 Bout Fitness, LLC. All rights reserved.
//

import CoreBluetooth

public final class PerformanceMonitor
{
    public static let DidUpdateStateNotification = Notification.Name("PerformanceMonitorDidUpdateStateNotification")

    /// Posted, with the monitor as its object, for every notification received from the PM5, before
    /// it is interpreted. The user info holds the characteristic's name (`RawDataKey.name`), the
    /// bytes exactly as received (`RawDataKey.data`) and when they arrived (`RawDataKey.date`).
    public static let DidReceiveRawDataNotification = Notification.Name("PerformanceMonitorDidReceiveRawDataNotification")

    public enum RawDataKey {
        public static let name = "name"
        public static let data = "data"
        public static let date = "date"
        /// A closure returning the notification's parsed values as `[ParsedField]`. It is only
        /// evaluated when called, so listeners that don't need the values cost nothing.
        public static let fields = "fields"
    }

    /// One value parsed out of a notification, such as `elapsedTime` = `12.34`. Enumerations show
    /// their case name, e.g. `rowingState` = `active`.
    public struct ParsedField {
        public let name:String
        public let value:String
    }
  
  //
  var peripheral:CBPeripheral
  lazy var peripheralDelegate = PeripheralDelegate()
  
  // MARK: Basic Information
  public var peripheralName:String { get { return peripheral.name ?? "Unknown" } }
  public var peripheralIdentifier:String { get { return peripheral.identifier.uuidString } }
  
  public var isConnected:Bool { get { return (peripheral.state == .connected) } }
  
  // MARK: Rowing Information
  public let averageCalories = Subject<C2CalorieCount>(value: 0)
  /// Average power over the whole workout, as reported by the PM5.
  public let averagePower = Subject<C2Power>(value: 0)
  public let averageDriveForce = Subject<C2DriveForce>(value: 0)
  public let averageHeartRate = Subject<C2HeartRate>(value: 0)
  public let averagePace = Subject<C2Pace>(value: 0)
  public let averageStrokeRate = Subject<C2StrokeRate>(value: 0)
  public let currentPace = Subject<C2Pace>(value: 0)
  public let distance = Subject<C2Distance>(value: 0)
  public let dragFactor = Subject<C2DragFactor>(value: 0)
  public let dragFactorAverage = Subject<C2DragFactor>(value: 0)
  public let driveLength = Subject<C2DriveLength>(value: 0)
  public let driveTime = Subject<C2DriveTime>(value: 0)
  public let elapsedTime = Subject<C2TimeInterval>(value: 0)
  public let endingHeartRate = Subject<C2HeartRate>(value: 0)
  public let heartRate = Subject<C2HeartRate>(value: 0)
  public let intervalAverageCalories = Subject<C2CalorieCount>(value: 0)
  public let intervalAveragePace = Subject<C2Pace>(value: 0)
  public let intervalAveragePower = Subject<C2Power>(value: 0)
  public let intervalAverageStrokeRate = Subject<C2StrokeRate>(value: 0)
  public let intervalCount = Subject<C2IntervalCount>(value: 0)
  public let intervalDistance = Subject<C2Distance>(value: 0)
  public let intervalNumber = Subject<C2IntervalCount>(value: 0)
  public let intervalPower = Subject<C2Power>(value: 0)
  public let intervalRestDistance = Subject<C2Distance>(value: 0)
  public let intervalRestHeartrate = Subject<C2HeartRate>(value: 0)
  public let intervalRestTime = Subject<C2TimeInterval>(value: 0)
  public let intervalSize = Subject<C2IntervalSize>(value: 0)
  public let intervalSpeed = Subject<C2Speed>(value: 0)
  public let intervalTime = Subject<C2TimeInterval>(value: 0)
  public let intervalTotalCalories = Subject<C2CalorieCount>(value: 0)
  public let intervalType = Subject<IntervalType?>(value: nil)
  public let intervalWorkHeartrate = Subject<C2HeartRate>(value: 0)
  public let lastSplitDistance = Subject<C2Distance>(value: 0)
  public let lastSplitTime = Subject<C2TimeInterval>(value: 0)
  public let maximumHeartRate = Subject<C2HeartRate>(value: 0)
  public let minimumHeartRate = Subject<C2HeartRate>(value: 0)
  public let peakDriveForce = Subject<C2DriveForce>(value: 0)
  public let projectedWorkDistance = Subject<C2Distance>(value: 0)
  public let projectedWorkTime = Subject<C2TimeInterval>(value: 0)
  public let recoveryHeartRate = Subject<C2HeartRate>(value: 0)
  public let restDistance = Subject<C2Distance>(value: 0)
  public let restTime = Subject<C2TimeInterval>(value: 0)
  public let rowingState = Subject<RowingState?>(value: nil)
  public let sampleRate = Subject<RowingStatusSampleRateType?>(value: nil)
  public let speed = Subject<C2Speed>(value: 0)
  public let splitAverageDragFactor = Subject<C2DragFactor>(value: 0)
  public let strokeCalories = Subject<C2CalorieCount>(value: 0)
  public let strokeCount = Subject<C2StrokeCount>(value: 0)
  public let strokeDistance = Subject<C2Distance>(value: 0)
  public let strokePower = Subject<C2Power>(value: 0)
  public let strokeRate = Subject<C2StrokeRate>(value: 0)
  public let strokeRecoveryTime = Subject<C2TimeInterval>(value: 0)
  public let strokeState = Subject<StrokeState?>(value: nil)
  public let totalCalories = Subject<C2CalorieCount>(value: 0)
  public let totalRestDistance = Subject<C2Distance>(value: 0)
  public let totalWorkDistance = Subject<C2Distance>(value: 0)
  public let watts = Subject<C2Power>(value: 0)
  public let workoutDuration = Subject<C2TimeInterval>(value: 0)
  public let workoutDurationType = Subject<WorkoutDurationType?>(value: nil)
  public let workoutState = Subject<WorkoutState?>(value: nil)
  public let workoutType = Subject<WorkoutType?>(value: nil)
  public let workPerStroke = Subject<C2Work>(value: 0)

  /// The force curve of the last completed stroke (16-bit samples, drive to recovery).
  /// Updated once all of the stroke's notification packets have arrived.
  public let forceCurve = Subject<[Int]>(value: [])
  private var forceCurvePoints = [Int]()
  private var forceCurveExpectedPackets = 0
  private var forceCurveReceivedPackets = 0
  
  // MARK: Heart Rate Belt
  public let manufacturerID = Subject<C2HeartRateBeltManufacturerID>(value: 0)
  public let deviceType = Subject<C2HeartRateBeltType>(value: 0)
  public let beltID = Subject<C2HeartRateBeltID>(value: 0)
  
  // MARK: - Initialization
  init(withPeripheral peripheral:CBPeripheral) {
    self.peripheral = peripheral
    
    peripheralDelegate.performanceMonitor = self
    peripheral.delegate = peripheralDelegate
  }
  
  // MARK: API
  public func reset() {
    averageCalories.value = 0
    averagePower.value = 0
    averageDriveForce.value = 0
    averagePace.value = 0
    currentPace.value = 0
    distance.value = 0
    dragFactor.value = 0
    driveLength.value = 0
    driveTime.value = 0
    elapsedTime.value = 0
    heartRate.value = 0
    intervalAverageCalories.value = 0
    intervalAveragePace.value = 0
    intervalAveragePower.value = 0
    intervalAverageStrokeRate.value = 0
    intervalCount.value = 0
    intervalDistance.value = 0
    intervalNumber.value = 0
    intervalPower.value = 0
    intervalRestDistance.value = 0
    intervalRestHeartrate.value = 0
    intervalRestTime.value = 0
    intervalSize.value = 0
    intervalSpeed.value = 0
    intervalTime.value = 0
    intervalTotalCalories.value = 0
    intervalWorkHeartrate.value = 0
    lastSplitDistance.value = 0
    lastSplitTime.value = 0
    peakDriveForce.value = 0
    projectedWorkDistance.value = 0
    projectedWorkTime.value = 0
    restDistance.value = 0
    restTime.value = 0
    speed.value = 0
    splitAverageDragFactor.value = 0
    strokeCalories.value = 0
    strokeCount.value = 0
    strokeDistance.value = 0
    strokePower.value = 0
    strokeRate.value = 0
    strokeRecoveryTime.value = 0
    totalCalories.value = 0
    totalRestDistance.value = 0
    totalWorkDistance.value = 0
    watts.value = 0
    workoutDuration.value = 0
    workPerStroke.value = 0
    
    manufacturerID.value = 0
    deviceType.value = 0
    beltID.value = 0
  }
  
  private struct PendingWrite {
    let service:CBUUID
    let characteristic:CBUUID
    let data:Data
  }
  private var pendingWrites = [PendingWrite]()

  private func discoveredCharacteristic(service serviceUUID:CBUUID, characteristic characteristicUUID:CBUUID) -> CBCharacteristic? {
    return peripheral.services?
      .first(where: { $0.uuid == serviceUUID })?
      .characteristics?
      .first(where: { $0.uuid == characteristicUUID })
  }

  /// Writes `data` to a characteristic. If the characteristic hasn't been discovered yet (e.g. the
  /// PM5 was already connected before this app used it), discovery is started and the write is
  /// made as soon as it completes. Returns false only if the PM5 isn't connected.
  private func write(_ data:Data, service:CBUUID, characteristic:CBUUID) -> Bool {
    guard isConnected else { return false }
    pendingWrites.append(PendingWrite(service: service, characteristic: characteristic, data: data))
    if discoveredCharacteristic(service: service, characteristic: characteristic) != nil {
      flushPendingWrites()
    } else if let svc = peripheral.services?.first(where: { $0.uuid == service }) {
      peripheral.discoverCharacteristics([characteristic], for: svc)
    } else {
      peripheral.discoverServices([service])
    }
    return true
  }

  /// Writes a raw CSAFE frame to the PM5 control (receive) characteristic.
  @discardableResult
  public func sendCSAFEFrame(_ frame:Data) -> Bool {
    return write(frame, service: Service.control.uuid, characteristic: ControlCharacteristic.command.uuid)
  }

  /// Sets how often the PM5 sends its general and additional status data.
  @discardableResult
  public func setStatusSampleRate(_ rate:RowingStatusSampleRateType) -> Bool {
    return write(Data([rate.rawValue]), service: Service.rowing.uuid,
                 characteristic: RowingCharacteristic.statusSampleRate.uuid)
  }

  /// Makes the writes that were waiting for their characteristic to be discovered.
  func flushPendingWrites() {
    pendingWrites.removeAll { pending in
      guard let characteristic = discoveredCharacteristic(service: pending.service,
                                                          characteristic: pending.characteristic)
      else { return false }
      let type:CBCharacteristicWriteType =
        characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
      peripheral.writeValue(pending.data, for: characteristic, type: type)
      return true
    }
  }

  // MARK: Force curve
  /// A curve is sent as several packets, always starting at sequence 0. Packets that arrive
  /// before a sequence 0 (joining mid-stroke) are ignored.
  func addForceCurvePacket(_ packet:RowingForceCurvePacket) {
    if packet.sequence == 0 {
      forceCurvePoints.removeAll()
      forceCurveReceivedPackets = 0
      forceCurveExpectedPackets = packet.totalPackets
    }
    guard forceCurveExpectedPackets > 0 else { return }

    forceCurvePoints.append(contentsOf: packet.points)
    forceCurveReceivedPackets += 1

    if forceCurveReceivedPackets >= forceCurveExpectedPackets {
      let curve = forceCurvePoints
      forceCurvePoints.removeAll()
      forceCurveReceivedPackets = 0
      forceCurveExpectedPackets = 0
      forceCurve.value = curve
    }
  }

  // MARK: -
  func updatePeripheralObservers() {
    print("[PerformanceMonitor]updatePeripheralObservers")
    
    peripheral.services?.forEach({ (service:CBService) -> () in
      print("Requesting notifications for \(service.description)")
      
      if let svc = Service(uuid: service.uuid) {
        peripheral.discoverCharacteristics(svc.characteristicUUIDs,
          for:  service)
        
        service.characteristics?.forEach({ (characteristic:CBCharacteristic) -> () in
          print("\t* \(characteristic)")
          peripheral.setNotifyValue(true, for: characteristic)
        })
      }
    })
  }
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// MARK: Equatable
public func ==(lhs:PerformanceMonitor, rhs:PerformanceMonitor) -> Bool {
  return (lhs.peripheral == rhs.peripheral)
}

// MARK: Hashable
extension PerformanceMonitor: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(peripheral.hashValue)
    }
}
