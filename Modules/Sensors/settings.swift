//
//  settings.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 23/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Settings: NSStackView, Settings_v {
    private var updateIntervalValue: Int = 3
    private var hidState: Bool
    private var fanSpeedState: Bool = false
    private var fansSyncState: Bool = false
    private var unknownSensorsState: Bool = false
    private var fanValueState: FanValue = .percentage
    
    public var callback: (() -> Void) = {}
    public var HIDcallback: (() -> Void) = {}
    public var unknownCallback: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var selectedHandler: (String) -> Void = {_ in }
    
    private let title: String
    private var list: [Sensor_p] = []
    private var sensorsPrefs: PreferencesSection?
    private var selectedSensor: String = "Average System Total"
    
    private struct FanCurveGroup {
        let scope: FanCurveScope
        let fans: [Fan]
        let section: PreferencesSection
        let chart: FanCurveChart
        let toggle: NSSwitch
    }
    private var fanCurveGroups: [FanCurveGroup] = []
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        self.hidState = SystemKit.shared.device.platform == .m1 ? true : false
        
        super.init(frame: NSRect.zero)
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        
        self.updateIntervalValue = Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: self.updateIntervalValue)
        self.hidState = Store.shared.bool(key: "\(self.title)_hid", defaultValue: self.hidState)
        self.fanSpeedState = Store.shared.bool(key: "\(self.title)_speed", defaultValue: self.fanSpeedState)
        self.fansSyncState = Store.shared.bool(key: "\(self.title)_fansSync", defaultValue: self.fansSyncState)
        self.unknownSensorsState = Store.shared.bool(key: "\(self.title)_unknown", defaultValue: self.unknownSensorsState)
        self.fanValueState = FanValue(rawValue: Store.shared.string(key: "\(self.title)_fanValue", defaultValue: self.fanValueState.rawValue)) ?? .percentage
        self.selectedSensor = Store.shared.string(key: "\(self.title)_sensor", defaultValue: self.selectedSensor)
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: selectView(
                action: #selector(self.changeUpdateInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateIntervalValue)"
            ))
        ]))
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: self.fanValueState.rawValue
            )),
            PreferencesRow(localizedString("Save the fan speed"), component: switchView(
                action: #selector(self.toggleSpeedState),
                state: self.fanSpeedState
            )),
            PreferencesRow(localizedString("Synchronize fan's control"), component: switchView(
                action: #selector(self.toggleFansSync),
                state: self.fansSyncState
            ))
        ]))
        
        var sensorsRows: [PreferencesRow] = [
            PreferencesRow(localizedString("Show unknown sensors"), component: switchView(
                action: #selector(self.toggleuUnknownSensors),
                state: self.unknownSensorsState
            ))
        ]
        if isARM {
            sensorsRows.append(PreferencesRow(localizedString("HID sensors"), component: switchView(
                action: #selector(self.toggleHID),
                state: self.hidState
            )))
        }
        sensorsRows.append(PreferencesRow(localizedString("Sensor to show"), id: "active_sensor", component: selectView(
            action: #selector(self.handleSelection),
            items: [],
            selected: self.selectedSensor)
        ))
        let sensorsPrefs = PreferencesSection(sensorsRows)
        self.sensorsPrefs = sensorsPrefs
        self.addArrangedSubview(sensorsPrefs)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        var sensors = self.list
        guard !sensors.isEmpty else {
            return
        }
        if !self.unknownSensorsState {
            sensors = sensors.filter({ $0.group != .unknown })
        }
        
        self.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
            v.removeFromSuperview()
        }
        
        self.loadFanCurves()
        
        var types: [SensorType] = []
        sensors.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        var buttonList: [KeyValue_t] = []
        types.forEach { (typ: SensorType) in
            let section = PreferencesSection(title: localizedString(typ.rawValue))
            section.identifier = NSUserInterfaceItemIdentifier("sensor")
            
            let filtered = sensors.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            groups.forEach { (group: SensorGroup) in
                filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                    let btn = switchView(
                        action: #selector(self.toggleSensor),
                        state: s.state
                    )
                    btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                    section.add(PreferencesRow(localizedString(s.name), component: btn))
                    buttonList.append(KeyValue_t(key: s.key, value: "\(localizedString(typ.rawValue)) - \(s.name)"))
                }
            }
            
            self.addArrangedSubview(section)
        }
        
        if let row = self.sensorsPrefs?.findRow("active_sensor") {
            self.sensorsPrefs?.setRowVisibility(row, newState: widgets.contains(where: { $0 == .mini }))
            row.replaceComponent(with: selectView(
                action: #selector(self.handleSelection),
                items: buttonList,
                selected: self.selectedSensor
            ))
        }
    }
    
    public func setList(_ list: [Sensor_p]?) {
        guard let list else { return }
        self.list = self.unknownSensorsState ? list : list.filter({ $0.group != .unknown })
        self.load(widgets: [])
    }
    
    public func usageCallback(_ sensors: [Sensor_p]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.fanCurveGroups.isEmpty, self.window?.isVisible ?? false else { return }
            
            let temperatures = sensors.filter({ $0.type == .temperature })
            let fans = FanCurveController.controllable(sensors)
            guard !fans.isEmpty, !temperatures.isEmpty else { return }
            
            self.fanCurveGroups.forEach { (group: FanCurveGroup) in
                let live = fans.filter { (f: Fan) in group.fans.contains(where: { $0.id == f.id }) }
                guard !live.isEmpty else { return }
                
                guard let key = FanCurveStore.sensor(group.scope, in: temperatures),
                      let sensor = temperatures.first(where: { $0.key == key }) else {
                    group.chart.setLive(nil)
                    group.section.setSubtitle("")
                    return
                }
                
                group.chart.setFloor(live.map({ (100*$0.minSpeed)/$0.maxSpeed }).max() ?? 0)
                group.chart.setLive(sensor.value)
                
                let enabled = FanCurveStore.enabled(group.scope)
                if (group.toggle.state == .on) != enabled {
                    group.toggle.state = enabled ? .on : .off
                    group.chart.active = enabled
                }
                
                guard enabled else {
                    group.section.setSubtitle("")
                    return
                }
                guard SMCHelper.shared.isInstalled else {
                    group.section.setSubtitle(localizedString("Install fan helper"))
                    return
                }
                
                let percentage = FanCurveStore.curve(group.scope).percentage(at: sensor.value)
                let speeds = live.map({ "\(FanCurveController.speed($0, percentage: percentage))" }).joined(separator: " / ")
                group.section.setSubtitle("\(sensor.formattedValue) → \(Int(percentage))% · \(speeds) RPM")
            }
        }
    }
    
    private func loadFanCurves() {
        self.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("fan_curve") }).forEach { v in
            v.removeFromSuperview()
        }
        self.fanCurveGroups = []
        
        let fans = FanCurveController.controllable(self.list)
        let temperatures = self.list.filter({ $0.type == .temperature })
        guard !fans.isEmpty, !temperatures.isEmpty else { return }
        
        let items = temperatures.map({ KeyValue_t(key: $0.key, value: $0.name) })
        var index = self.arrangedSubviews.firstIndex(where: { $0 == self.sensorsPrefs }) ?? self.arrangedSubviews.count
        
        var groups: [(scope: FanCurveScope, fans: [Fan], title: String)] = []
        if FanCurveStore.synced || fans.count == 1 {
            groups = [(FanCurveStore.scope(fans[0].id), fans, localizedString("Fan curve"))]
        } else {
            groups = fans.map({ (.fan($0.id), [$0], "\(localizedString("Fan curve")): \($0.name)") })
        }
        
        groups.enumerated().forEach { (tag: Int, group: (scope: FanCurveScope, fans: [Fan], title: String)) in
            let built = self.fanCurveGroup(group.scope, fans: group.fans, title: group.title,
                                           items: items, temperatures: temperatures, tag: tag)
            self.insertArrangedSubview(built.section, at: index)
            index += 1
            
            built.chart.widthAnchor.constraint(
                equalTo: self.widthAnchor, constant: -(Constants.Settings.margin*2)
            ).isActive = true
            
            self.fanCurveGroups.append(built)
        }
    }
    
    private func fanCurveGroup(_ scope: FanCurveScope, fans: [Fan], title: String,
                               items: [KeyValue_t], temperatures: [Sensor_p], tag: Int) -> FanCurveGroup {
        let id = NSUserInterfaceItemIdentifier("\(tag)")
        let enabled = FanCurveStore.enabled(scope)
        
        let toggle = switchView(action: #selector(self.toggleFanCurve), state: enabled)
        toggle.identifier = id
        
        let selected = FanCurveStore.sensor(scope, in: temperatures) ?? ""
        if !selected.isEmpty, FanCurveStore.savedSensor(scope).isEmpty {
            FanCurveStore.setSensor(scope, selected)
        }
        
        let select = selectView(action: #selector(self.changeFanCurveSensor), items: items, selected: selected)
        select.identifier = id
        
        let reset = buttonView(#selector(self.resetFanCurve), text: localizedString("Reset to default"))
        reset.identifier = id
        
        let chart = FanCurveChart(
            curve: FanCurveStore.curve(scope),
            floorPercentage: fans.map({ (100*$0.minSpeed)/$0.maxSpeed }).max() ?? 0
        )
        chart.active = enabled
        chart.callback = { (curve: FanCurve) in
            FanCurveStore.setCurve(scope, curve)
            fans.forEach { FanCurveController.shared.resetSmoothing($0.id) }
        }
        
        let section = PreferencesSection(title: title, subtitle: "", [
            PreferencesRow(
                fans.count > 1
                    ? localizedString("Control these fans with a curve")
                    : localizedString("Control this fan with a curve"),
                component: toggle
            ),
            PreferencesRow(localizedString("Temperature sensor"), component: select)
        ])
        section.identifier = NSUserInterfaceItemIdentifier("fan_curve")
        section.add(chart)
        section.add(PreferencesRow(nil, localizedString("Drag the points to set a fan speed for a temperature"), component: reset))
        
        return FanCurveGroup(scope: scope, fans: fans, section: section, chart: chart, toggle: toggle)
    }
    
    private func group(_ sender: NSControl) -> FanCurveGroup? {
        guard let tag = sender.identifier?.rawValue, let i = Int(tag),
              self.fanCurveGroups.indices.contains(i) else { return nil }
        return self.fanCurveGroups[i]
    }
    
    private func claim(_ fans: [Fan]) {
        fans.forEach { (f: Fan) in
            var fan = f
            fan.customMode = nil
            fan.customSpeed = nil
        }
    }
    
    @objc private func toggleFanCurve(_ sender: NSControl) {
        guard let group = self.group(sender) else { return }
        let state = controlState(sender)
        
        FanCurveStore.setEnabled(group.scope, state)
        group.chart.active = state
        
        if state {
            self.claim(group.fans)
        } else {
            FanCurveController.shared.disable(group.fans.map({ $0.id }))
            group.section.setSubtitle("")
        }
    }
    @objc private func changeFanCurveSensor(_ sender: NSPopUpButton) {
        guard let group = self.group(sender), let key = sender.selectedItem?.representedObject as? String else { return }
        FanCurveStore.setSensor(group.scope, key)
        group.fans.forEach { FanCurveController.shared.resetSmoothing($0.id) }
        group.chart.setLive(nil)
    }
    @objc private func resetFanCurve(_ sender: NSControl) {
        guard let group = self.group(sender) else { return }
        FanCurveStore.resetCurve(group.scope)
        group.chart.setCurve(FanCurve.default)
        group.fans.forEach { FanCurveController.shared.resetSmoothing($0.id) }
    }
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)", value: controlState(sender))
        self.callback()
    }
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateInterval", value: value)
        self.setInterval(value)
    }
    @objc private func toggleSpeedState(_ sender: NSControl) {
        self.fanSpeedState = controlState(sender)
        Store.shared.set(key: "\(self.title)_speed", value: self.fanSpeedState)
        self.callback()
    }
    @objc private func toggleHID(_ sender: NSControl) {
        self.hidState = controlState(sender)
        Store.shared.set(key: "\(self.title)_hid", value: self.hidState)
        self.HIDcallback()
    }
    @objc private func toggleFansSync(_ sender: NSControl) {
        let previous = self.fansSyncState
        self.fansSyncState = controlState(sender)
        Store.shared.set(key: "\(self.title)_fansSync", value: self.fansSyncState)
        guard previous != self.fansSyncState else { return }
        
        let fans = FanCurveController.controllable(self.list)
        if self.fansSyncState, let first = fans.first {
            FanCurveStore.seedIfUnset(.synced, from: .fan(first.id))
            if FanCurveStore.enabled(.synced) {
                self.claim(fans)
            }
        }
        
        fans.forEach { FanCurveController.shared.resetSmoothing($0.id) }
        self.loadFanCurves()
    }
    @objc private func toggleuUnknownSensors(_ sender: NSControl) {
        self.unknownSensorsState = controlState(sender)
        Store.shared.set(key: "\(self.title)_unknown", value: self.unknownSensorsState)
        self.unknownCallback()
    }
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            self.fanValueState = value
            Store.shared.set(key: "\(self.title)_fanValue", value: self.fanValueState.rawValue)
            self.callback()
        }
    }
    @objc private func handleSelection(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let id = item.representedObject as? String else { return }
        self.selectedSensor = id
        Store.shared.set(key: "\(self.title)_sensor", value: self.selectedSensor)
        self.selectedHandler(self.selectedSensor)
    }
}
