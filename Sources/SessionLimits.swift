import Foundation

struct SessionLimits: Codable, Equatable {
    enum Heat: Int, Codable, CaseIterable {
        case off, elevated, serious, critical

        var title: String {
            switch self {
            case .off: "Off"
            case .elevated: "Elevated"
            case .serious: "Serious"
            case .critical: "Critical"
            }
        }
    }

    var minutes = 0
    var heat = Heat.off
    var battery = 0

    static let lidClosedDefault = Self(battery: 20)

    var isValid: Bool { (0...1440).contains(minutes) && (0...100).contains(battery) }

    func deadline(from start: Date = .now) -> Date? {
        minutes == 0 ? nil : start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    func powerLimitReached(thermalState: ProcessInfo.ThermalState, batteryPercent: Int?) -> String? {
        if heat != .off && thermalState.rawValue >= heat.rawValue {
            return "Thermal state reached \(heat.title.lowercased())."
        }
        if battery > 0, let batteryPercent, batteryPercent <= battery {
            return "Battery charge reached \(battery)% or below while unplugged."
        }
        return nil
    }

    static func unpluggedBatteryPercent(_ output: String) -> Int? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.first == "Now drawing from 'Battery Power'" else { return nil }
        for line in lines.dropFirst() where line.contains("-InternalBattery-") {
            guard let range = line.range(of: #"\b[0-9]{1,3}(?=%;)"#, options: .regularExpression),
                  let percent = Int(line[range]), (0...100).contains(percent)
            else { continue }
            return percent
        }
        return nil
    }
}
