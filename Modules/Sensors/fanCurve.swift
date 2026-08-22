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

// MARK: - Chart

internal class FanCurveChart: NSView {
    private let padding: NSEdgeInsets = NSEdgeInsets(top: 12, left: 38, bottom: 20, right: 14)
    private let handle: CGFloat = 4.5
    private let grab: CGFloat = 12
    private let height: CGFloat = 168
    
    private var curve: FanCurve
    private var floorPercentage: Double
    private var dragging: Int?
    private var live: Double?
    
    internal var callback: (FanCurve) -> Void = { _ in }
    internal var active: Bool = false {
        didSet {
            guard self.active != oldValue else { return }
            if !self.active {
                self.dragging = nil
            }
            self.needsDisplay = true
        }
    }
    
    internal init(curve: FanCurve, floorPercentage: Double) {
        self.curve = curve
        self.floorPercentage = floorPercentage
        
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 168))
        
        self.wantsLayer = true
        self.heightAnchor.constraint(equalToConstant: self.height).isActive = true
        self.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func setCurve(_ curve: FanCurve) {
        guard self.dragging == nil, self.curve != curve else { return }
        self.curve = curve
        self.needsDisplay = true
    }
    
    internal func setFloor(_ percentage: Double) {
        guard self.floorPercentage != percentage else { return }
        self.floorPercentage = percentage
        self.needsDisplay = true
    }
    
    internal func setLive(_ temperature: Double?) {
        guard self.live != temperature else { return }
        self.live = temperature
        self.needsDisplay = true
    }
    
    // MARK: - geometry
    
    private var plot: NSRect {
        NSRect(
            x: self.padding.left,
            y: self.padding.bottom,
            width: max(self.bounds.width - self.padding.left - self.padding.right, 1),
            height: max(self.bounds.height - self.padding.top - self.padding.bottom, 1)
        )
    }
    
    private func position(_ point: FanCurvePoint) -> CGPoint {
        CGPoint(x: self.x(point.temperature), y: self.y(point.percentage))
    }
    
    private func x(_ temperature: Double) -> CGFloat {
        let span = FanCurve.maxTemperature - FanCurve.minTemperature
        let ratio = (temperature.clampedTo(FanCurve.minTemperature, FanCurve.maxTemperature) - FanCurve.minTemperature) / span
        return self.plot.minX + self.plot.width * CGFloat(ratio)
    }
    
    private func y(_ percentage: Double) -> CGFloat {
        self.plot.minY + self.plot.height * CGFloat(percentage.clampedTo(0, 100) / 100)
    }
    
    private func value(_ point: CGPoint) -> FanCurvePoint {
        let plot = self.plot
        let span = FanCurve.maxTemperature - FanCurve.minTemperature
        return FanCurvePoint(
            temperature: FanCurve.minTemperature + span * Double((point.x - plot.minX) / plot.width),
            percentage: Double((point.y - plot.minY) / plot.height) * 100
        )
    }
    
    private func nearest(_ point: CGPoint) -> Int? {
        var found: (index: Int, distance: CGFloat)?
        for (i, p) in self.curve.points.enumerated() {
            let position = self.position(p)
            let distance = hypot(position.x - point.x, position.y - point.y)
            guard distance <= self.grab else { continue }
            if found == nil || distance < found!.distance {
                found = (i, distance)
            }
        }
        return found?.index
    }
}

// MARK: - Chart drawing

extension FanCurveChart {
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let plot = self.plot
        guard plot.width > 1, plot.height > 1 else { return }
        
        let accent: NSColor = self.active ? .controlAccentColor : .tertiaryLabelColor
        let hairline: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .light),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        
        (isDarkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.03).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()
        
        (isDarkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.07).setStroke()
        for step in stride(from: 0.0, through: 100.0, by: 25.0) {
            let y = self.y(step)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = hairline
            line.stroke()
            
            let label = NSAttributedString(string: "\(Int(step))%", attributes: attributes)
            label.draw(at: CGPoint(x: plot.minX - label.size().width - 5, y: y - label.size().height/2))
        }
        for step in stride(from: FanCurve.minTemperature, through: FanCurve.maxTemperature, by: 20.0) {
            let x = self.x(step)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = hairline
            line.stroke()
            
            let label = NSAttributedString(string: temperature(step), attributes: attributes)
            let width = label.size().width
            label.draw(at: CGPoint(
                x: (x - width/2).clampedTo(0, max(self.bounds.width - width, 0)),
                y: plot.minY - label.size().height - 3
            ))
        }
        
        let points = self.curve.points.map({ self.position($0) })
        guard let first = points.first, let last = points.last else { return }
        
        let line = NSBezierPath()
        line.move(to: CGPoint(x: plot.minX, y: first.y))
        points.forEach({ line.line(to: $0) })
        line.line(to: CGPoint(x: plot.maxX, y: last.y))
        
        let fill = line.copy() as! NSBezierPath
        fill.line(to: CGPoint(x: plot.maxX, y: plot.minY))
        fill.line(to: CGPoint(x: plot.minX, y: plot.minY))
        fill.close()
        accent.withAlphaComponent(0.12).setFill()
        fill.fill()
        
        self.drawFloor(plot, hairline: hairline)
        
        accent.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()
        
        self.drawLive(plot, hairline: hairline)
        
        for (i, point) in points.enumerated() {
            let radius = self.dragging == i ? self.handle + 1.5 : self.handle
            let path = NSBezierPath(ovalIn: NSRect(
                x: point.x - radius, y: point.y - radius, width: radius*2, height: radius*2
            ))
            (isDarkMode ? NSColor.black : NSColor.white).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        
        if let index = self.dragging, self.curve.points.indices.contains(index) {
            let point = self.curve.points[index]
            self.drawReadout(
                "\(temperature(point.temperature)) · \(Int(point.percentage))%",
                near: points[index]
            )
        }
    }
    
    private func drawFloor(_ plot: NSRect, hairline: CGFloat) {
        guard self.floorPercentage > 0 else { return }
        
        let top = self.y(self.floorPercentage)
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: top - plot.minY)).fill()
        
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: plot.minX, y: top))
        edge.line(to: CGPoint(x: plot.maxX, y: top))
        edge.lineWidth = hairline * 2
        edge.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        edge.stroke()
    }
    
    private func drawLive(_ plot: NSRect, hairline: CGFloat) {
        guard let live = self.live else { return }
        
        let x = self.x(live)
        let marker = NSBezierPath()
        marker.move(to: CGPoint(x: x, y: plot.minY))
        marker.line(to: CGPoint(x: x, y: plot.maxY))
        marker.lineWidth = hairline * 2
        marker.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        marker.stroke()
        
        let y = self.y(self.curve.percentage(at: live))
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: x-3, y: y-3, width: 6, height: 6)).fill()
    }
    
    private func drawReadout(_ text: String, near point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        let plot = self.plot
        
        var origin = CGPoint(x: point.x - size.width/2, y: point.y + self.handle + 7)
        origin.x = origin.x.clampedTo(plot.minX + 3, plot.maxX - size.width - 3)
        if origin.y + size.height + 3 > plot.maxY {
            origin.y = point.y - self.handle - size.height - 7
        }
        
        let box = NSBezierPath(
            roundedRect: NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4),
            xRadius: 3, yRadius: 3
        )
        (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        box.stroke()
        
        label.draw(at: origin)
    }
}

// MARK: - Chart interaction

extension FanCurveChart {
    public override func mouseDown(with event: NSEvent) {
        guard self.active else { return }
        self.dragging = self.nearest(self.convert(event.locationInWindow, from: nil))
        self.needsDisplay = true
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard self.active, let index = self.dragging, self.curve.points.indices.contains(index) else { return }
        
        var point = self.value(self.convert(event.locationInWindow, from: nil))
        
        let lower = index > 0 ? self.curve.points[index-1].temperature + 1 : FanCurve.minTemperature
        let upper = index < self.curve.points.count-1 ? self.curve.points[index+1].temperature - 1 : FanCurve.maxTemperature
        point.temperature = point.temperature.rounded().clampedTo(lower, upper)
        point.percentage = point.percentage.rounded().clampedTo(0, 100)
        
        guard self.curve.points[index] != point else { return }
        self.curve.points[index] = point
        self.needsDisplay = true
    }
    
    public override func mouseUp(with event: NSEvent) {
        guard self.dragging != nil else { return }
        self.dragging = nil
        self.needsDisplay = true
        self.callback(self.curve)
    }
}
