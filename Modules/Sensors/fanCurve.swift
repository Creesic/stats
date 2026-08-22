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

// MARK: - Controller

internal final class FanCurveController {
    static let shared = FanCurveController()
    
    private struct State {
        var temperature: Double
        var speed: Int
        var ts: TimeInterval
    }
    
    private let deadband: Double = 25
    private let refresh: TimeInterval = 60
    private let smoothing: Double = 0.4
    private static let wakeDelay: TimeInterval = 3
    
    private let queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Sensors.fanCurve")
    private var state: [Int: State] = [:]
    private var driven: Set<Int> = []
    private var asleep: Bool = false
    
    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(self.sleepListener), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(self.wakeListener), name: NSWorkspace.didWakeNotification, object: nil
        )
    }
    
    internal func tick(_ sensors: [Sensor_p]) {
        let fans = FanCurveController.controllable(sensors)
        guard !fans.isEmpty else { return }
        let enabled = fans.filter({ FanCurveStore.enabled(FanCurveStore.scope($0.id)) })
        let temperatures = enabled.isEmpty ? [] : sensors.filter({ $0.type == .temperature })
        
        self.queue.async { [weak self] in
            guard let self, !self.asleep else { return }
            
            self.handBack(self.driven.subtracting(enabled.map({ $0.id })))
            
            guard !enabled.isEmpty, SMCHelper.shared.isInstalled else { return }
            enabled.forEach { self.apply($0, temperatures) }
        }
    }
    
    internal func release(_ id: Int) {
        self.queue.sync {
            self.state.removeValue(forKey: id)
            self.driven.remove(id)
        }
    }
    
    internal func isDriving(_ id: Int) -> Bool {
        self.queue.sync { self.driven.contains(id) }
    }
    
    internal func resetSmoothing(_ id: Int) {
        self.queue.async { [weak self] in
            self?.state.removeValue(forKey: id)
        }
    }
    
    internal func disable(_ ids: [Int]) {
        self.queue.async { [weak self] in
            self?.handBack(Set(ids))
        }
    }
    
    internal func releaseAll() {
        self.queue.sync {
            self.handBack(self.driven)
        }
    }
    
    private func handBack(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        ids.forEach { self.state.removeValue(forKey: $0) }
        guard SMCHelper.shared.isInstalled else { return }
        ids.forEach { SMCHelper.shared.setFanMode($0, mode: FanMode.automatic.rawValue) }
        self.driven.subtract(ids)
    }
    
    internal static func controllable(_ sensors: [Sensor_p]) -> [Fan] {
        sensors.compactMap({ $0 as? Fan }).filter({
            !$0.isComputed && $0.id >= 0 && $0.minSpeed >= 0 && $0.maxSpeed > 1 && $0.maxSpeed > $0.minSpeed
        })
    }
    
    internal static func speed(_ fan: Fan, percentage: Double) -> Int {
        Int((((fan.maxSpeed * percentage) / 100).clampedTo(fan.minSpeed, fan.maxSpeed)).rounded())
    }
    
    private func apply(_ fan: Fan, _ temperatures: [Sensor_p]) {
        let scope = FanCurveStore.scope(fan.id)
        guard FanCurveStore.enabled(scope) else { return }
        
        guard let key = FanCurveStore.sensor(scope, in: temperatures),
              let sensor = temperatures.first(where: { $0.key == key }), sensor.value > 0 else {
            if self.driven.contains(fan.id) {
                self.handBack([fan.id])
            }
            return
        }
        
        let now = ProcessInfo.processInfo.systemUptime
        let previous = self.state[fan.id]
        
        var temperature = sensor.value
        if let previous {
            temperature = previous.temperature + (sensor.value - previous.temperature) * self.smoothing
        }
        
        let speed = FanCurveController.speed(fan, percentage: FanCurveStore.curve(scope).percentage(at: temperature))
        let moved = previous == nil || abs(Double(speed - (previous?.speed ?? 0))) >= self.deadband
        let stale = now - (previous?.ts ?? 0) >= self.refresh
        
        guard moved || stale else {
            self.state[fan.id] = State(temperature: temperature, speed: previous?.speed ?? speed, ts: previous?.ts ?? now)
            return
        }
        
        SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
        SMCHelper.shared.setFanSpeed(fan.id, speed: speed)
        self.driven.insert(fan.id)
        self.state[fan.id] = State(temperature: temperature, speed: speed, ts: now)
    }
    
    @objc private func sleepListener() {
        self.queue.sync {
            self.asleep = true
            self.handBack(self.driven)
        }
    }
    
    @objc private func wakeListener() {
        self.queue.asyncAfter(deadline: .now() + FanCurveController.wakeDelay) { [weak self] in
            guard let self else { return }
            self.state.removeAll()
            self.asleep = false
        }
    }
}
