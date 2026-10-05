//
//  PeripheralDelegate.swift
//  Pods
//
//  Created by Jesse Curry on 9/30/15.
//  Copyright © 2015 Bout Fitness, LLC. All rights reserved.
//

import CoreBluetooth

final class PeripheralDelegate: NSObject, CBPeripheralDelegate {
    weak var performanceMonitor:PerformanceMonitor?
    
    // MARK: Services
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        
        print("[PerformanceMonitor]didDiscoverServices:")
        peripheral.services?.forEach({ (service:CBService) -> () in
            print("\t* \(service.description)")
            
            if let svc = Service(uuid: service.uuid) {
                peripheral.discoverCharacteristics(svc.characteristicUUIDs, for: service)
            }
        })
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        print("[PerformanceMonitor]didDiscoverIncludedServicesForService")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        print("[PerformanceMonitor]didModifyServices")
    }
    
    // MARK: Characteristics
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("[PerformanceMonitor]didDiscoverCharacteristicsForService")
        service.characteristics?.forEach({ (characteristic:CBCharacteristic) -> () in
            peripheral.setNotifyValue(true, for: characteristic)
        })
        performanceMonitor?.flushPendingWrites()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        print("[PerformanceMonitor]didDiscoverDescriptorsForCharacteristic")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        var known: Characteristic?
        if let characteristicService = characteristic.service,
           let svc = Service(uuid: characteristicService.uuid) {
            known = svc.characteristic(uuid: characteristic.uuid)
        }
        let model = known?.parse(data: characteristic.value)

        if let data = characteristic.value, let pm = performanceMonitor {
            let name = known.map { "\(type(of: $0)).\($0)" } ?? "unknown.\(characteristic.uuid.uuidString)"
            let fields: () -> [PerformanceMonitor.ParsedField] = { Self.parsedFields(of: model) }
            NotificationCenter.default.post(
                name: PerformanceMonitor.DidReceiveRawDataNotification,
                object: pm,
                userInfo: [PerformanceMonitor.RawDataKey.name: name,
                           PerformanceMonitor.RawDataKey.data: data,
                           PerformanceMonitor.RawDataKey.date: Date(),
                           PerformanceMonitor.RawDataKey.fields: fields])
        }

        if let model, let pm = performanceMonitor {
            model.updatePerformanceMonitor(performanceMonitor: pm)
        }
    }

    /// The stored properties of a parsed notification, by name.
    private static func parsedFields(of model: CharacteristicModel?) -> [PerformanceMonitor.ParsedField] {
        guard let model else { return [] }
        return Mirror(reflecting: model).children.compactMap { child in
            guard let label = child.label, label != "DataLength" else { return nil }
            return PerformanceMonitor.ParsedField(name: label, value: describe(child.value))
        }
    }

    private static func describe(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return "nil" }
            return describe(wrapped.value)
        }
        return String(describing: value)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        
        print("[PerformanceMonitor]didUpdateValueForDescriptor")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        
        print("[PerformanceMonitor]didWriteValueForDescriptor")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        
        print("[PerformanceMonitor]didWriteValueForCharacteristic error: \(String(describing: error))")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        
        print("[PerformanceMonitor]didUpdateNotificationStateForCharacteristic")
    }
    
    // MARK: Signal Strength
    func peripheralDidUpdateRSSI(_ peripheral: CBPeripheral, error: Error?) {
        
        print("[PerformanceMonitor]didUpdateRSSI")
    }
    
    // MARK: Name
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        
        print("[PerformanceMonitor]didUpdateName")
    }
}
