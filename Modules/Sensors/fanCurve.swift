//
//  fanCurve.swift
//  Sensors
//
//  Created by David on 22/08/2026.
//  Using Swift 6.0.
//  Running on macOS 26.5.
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

fileprivate extension FloatingPoint {
    func clampedTo(_ low: Self, _ high: Self) -> Self {
        Swift.min(Swift.max(self, low), high)
    }
}

// MARK: - Model

internal struct FanCurvePoint: Codable, Equatable {
    var temperature: Double
    var percentage: Double
}

internal struct FanCurve: Codable, Equatable {
    static let count: Int = 5
    static let minTemperature: Double = 20
    static let maxTemperature: Double = 100
    
    static let `default`: FanCurve = FanCurve(points: [
        FanCurvePoint(temperature: 30, percentage: 25),
        FanCurvePoint(temperature: 50, percentage: 40),
        FanCurvePoint(temperature: 65, percentage: 55),
        FanCurvePoint(temperature: 80, percentage: 75),
        FanCurvePoint(temperature: 95, percentage: 100)
    ])
    
    var points: [FanCurvePoint]
    
    func percentage(at temperature: Double) -> Double {
        guard let first = self.points.first, let last = self.points.last else { return 0 }
        if temperature <= first.temperature { return first.percentage }
        if temperature >= last.temperature { return last.percentage }
        
        for i in 0..<(self.points.count - 1) {
            let left = self.points[i]
            let right = self.points[i+1]
            guard temperature >= left.temperature && temperature <= right.temperature else { continue }
            let span = right.temperature - left.temperature
            guard span > 0 else { return right.percentage }
            return left.percentage + (right.percentage - left.percentage) * ((temperature - left.temperature) / span)
        }
        
        return last.percentage
    }
    
    func normalized() -> FanCurve {
        var list = self.points
        for i in list.indices {
            list[i].temperature = list[i].temperature.clampedTo(FanCurve.minTemperature, FanCurve.maxTemperature)
            list[i].percentage = list[i].percentage.clampedTo(0, 100)
        }
        list.sort { $0.temperature < $1.temperature }
        return FanCurve(points: list)
    }
}

// MARK: - Store

internal enum FanCurveScope: Equatable {
    case fan(Int)
    case synced
    
    fileprivate var prefix: String {
        switch self {
        case .fan(let id): return "fan_\(id)"
        case .synced: return "fanSync"
        }
    }
}

internal enum FanCurveStore {
    static var synced: Bool {
        Store.shared.bool(key: "Sensors_fansSync", defaultValue: false)
    }
    static func scope(_ id: Int) -> FanCurveScope {
        FanCurveStore.synced ? .synced : .fan(id)
    }
    
    static func curve(_ scope: FanCurveScope) -> FanCurve {
        guard let data = Store.shared.data(key: "\(scope.prefix)_curve"),
              let curve = try? JSONDecoder().decode(FanCurve.self, from: data),
              curve.points.count == FanCurve.count else { return FanCurve.default }
        return curve.normalized()
    }
    static func setCurve(_ scope: FanCurveScope, _ curve: FanCurve) {
        guard let data = try? JSONEncoder().encode(curve.normalized()) else { return }
        Store.shared.set(key: "\(scope.prefix)_curve", value: data)
    }
    static func resetCurve(_ scope: FanCurveScope) {
        Store.shared.remove("\(scope.prefix)_curve")
    }
    
    static func enabled(_ scope: FanCurveScope) -> Bool {
        Store.shared.bool(key: "\(scope.prefix)_curveEnabled", defaultValue: false)
    }
    static func setEnabled(_ scope: FanCurveScope, _ state: Bool) {
        Store.shared.set(key: "\(scope.prefix)_curveEnabled", value: state)
    }
    
    static func setSensor(_ scope: FanCurveScope, _ key: String) {
        Store.shared.set(key: "\(scope.prefix)_curveSensor", value: key)
    }
    static func savedSensor(_ scope: FanCurveScope) -> String {
        Store.shared.string(key: "\(scope.prefix)_curveSensor", defaultValue: "")
    }
    
    static func sensor(_ scope: FanCurveScope, in list: [Sensor_p]) -> String? {
        let available = list.filter({ $0.type == .temperature })
        guard !available.isEmpty else { return nil }
        
        let saved = FanCurveStore.savedSensor(scope)
        if !saved.isEmpty, available.contains(where: { $0.key == saved }) { return saved }
        
        for key in ["Hottest CPU", "Average CPU", "TC0P", "TC0D"] where available.contains(where: { $0.key == key }) {
            return key
        }
        if let cpu = available.first(where: { $0.group == .CPU }) { return cpu.key }
        return available.first?.key
    }
    
    static func seedIfUnset(_ target: FanCurveScope, from source: FanCurveScope) {
        guard Store.shared.data(key: "\(target.prefix)_curve") == nil else { return }
        FanCurveStore.setCurve(target, FanCurveStore.curve(source))
        FanCurveStore.setEnabled(target, FanCurveStore.enabled(source))
        let sensor = FanCurveStore.savedSensor(source)
        if !sensor.isEmpty {
            FanCurveStore.setSensor(target, sensor)
        }
    }
}
