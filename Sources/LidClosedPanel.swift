import SwiftUI

enum PanelMode: Hashable {
    case lidClosed, keepAwake

    var title: String { self == .lidClosed ? "Lid Closed Mode" : "Keep Awake" }
    var detail: String { self == .lidClosed ? "Runs with the lid closed" : "Keeps the display on while open" }
    var symbol: String { self == .lidClosed ? "laptopcomputer" : "cup.and.saucer" }
    var defaultLimits: SessionLimits { self == .lidClosed ? .lidClosedDefault : SessionLimits() }
    var minimumBattery: Int { self == .lidClosed ? 1 : 0 }
    var defaultsKey: String { self == .lidClosed ? "lidClosedSessionLimits" : "keepAwakeSessionLimits" }
}

@MainActor
final class PanelState: ObservableObject {
    struct Mode: Equatable {
        var active = false
        var saved = SessionLimits()
        var summary = ""
        var availability: String?
        var managedExternally = false
    }

    struct Snapshot: Equatable {
        var status = "Inactive — normal sleep behavior"
        var lid = Mode()
        var awake = Mode()
    }

    @Published var snapshot = Snapshot()
}

struct LidClosedPanel: View {
    @ObservedObject var panel: PanelState
    let toggle: (PanelMode) -> Void
    let save: (SessionLimits, PanelMode) -> Void
    let quit: () -> Void

    @State private var expanded: PanelMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modeCard(.lidClosed, panel.snapshot.lid)
            modeCard(.keepAwake, panel.snapshot.awake)
            HStack {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("v\(version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Version \(version)")
                }
                Spacer()
                Button("Quit LidClosed", action: quit)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 352)
        .fixedSize(horizontal: true, vertical: true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: expanded)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("LidClosed")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(panel.snapshot.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }

    private func modeCard(_ mode: PanelMode, _ state: PanelState.Mode) -> some View {
        ModeCard(
            mode: mode,
            state: state,
            expanded: expanded == mode,
            edit: { expanded = expanded == mode ? nil : mode },
            toggle: { toggle(mode) },
            save: { save($0, mode) }
        )
    }
}

private struct ModeCard: View {
    let mode: PanelMode
    let state: PanelState.Mode
    let expanded: Bool
    let edit: () -> Void
    let toggle: () -> Void
    let save: (SessionLimits) -> Void

    @State private var draft = LimitsDraft(SessionLimits())
    @State private var hasDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(state.active ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(state.managedExternally ? "Sleep is managed outside LidClosed" : mode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if state.managedExternally {
                    Button("Details", action: toggle).controlSize(.small)
                } else {
                    Toggle(mode.title, isOn: Binding(get: { state.active }, set: { _ in toggle() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .keyboardShortcut(mode == .lidClosed ? "t" : "k")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    if !hasDraft {
                        draft = LimitsDraft(state.saved)
                        hasDraft = true
                    }
                    edit()
                } label: {
                    Label(expanded ? "Hide limits" : "Edit limits", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("\(expanded ? "Hide" : "Edit") \(mode.title) limits")
            }

            if expanded {
                Divider()
                if let availability = state.availability {
                    Label(availability, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LimitsFields(draft: $draft, minimumBattery: mode.minimumBattery) {
                        save($0)
                        hasDraft = false
                        edit()
                    } cancel: {
                        hasDraft = false
                        edit()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.09))
                .allowsHitTesting(false)
        }
    }

    private var summary: String {
        if state.managedExternally { return "Controlled externally" }
        if state.availability != nil && !state.active { return "Custom limits unavailable" }
        return state.summary
    }
}

private struct LimitsDraft {
    static let presets = [0, 15, 30, 60, 120, 240, 480]

    var preset: Int?
    var minutes: String
    var battery: String
    var heat: SessionLimits.Heat

    init(_ limits: SessionLimits) {
        preset = Self.presets.contains(limits.minutes) ? limits.minutes : nil
        minutes = limits.minutes > 0 ? String(limits.minutes) : ""
        battery = String(limits.battery)
        heat = limits.heat
    }
}

private struct LimitsFields: View {
    @Binding var draft: LimitsDraft
    let minimumBattery: Int
    let save: (SessionLimits) -> Void
    let cancel: () -> Void

    private enum Field: Hashable { case duration, battery }
    @FocusState private var focus: Field?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Duration")
                    Picker("Duration", selection: $draft.preset) {
                        ForEach(LimitsDraft.presets, id: \.self) { preset in
                            Text(preset == 0 ? "Unlimited" : "\(preset) min").tag(Optional(preset))
                        }
                        Text("Custom…").tag(nil as Int?)
                    }
                    .labelsHidden()
                }
                if draft.preset == nil {
                    GridRow {
                        Text("Minutes")
                        TextField("1–1440", text: $draft.minutes)
                            .accessibilityLabel("Custom duration in minutes")
                            .focused($focus, equals: .duration)
                    }
                }
                GridRow {
                    Text("Thermal level")
                    Picker("Thermal level", selection: $draft.heat) {
                        ForEach(SessionLimits.Heat.allCases, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Battery cutoff")
                    HStack(spacing: 6) {
                        TextField("Percent", text: $draft.battery)
                            .accessibilityLabel("Battery cutoff percentage while unplugged")
                            .focused($focus, equals: .battery)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
            }
            .controlSize(.small)
            .font(.subheadline)
            .onSubmit(submit)

            Text(error ?? (minimumBattery == 0
                ? "Applies next session. Battery cutoff works unplugged; 0% turns it off."
                : "Applies next session. Battery cutoff works unplugged."))
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save limits", action: submit)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private func submit() {
        let minutes = draft.preset ?? Int(draft.minutes.trimmingCharacters(in: .whitespaces))
        guard let minutes, (0...1440).contains(minutes), draft.preset != nil || minutes > 0 else {
            error = "Enter a duration from 1 to 1,440 minutes."
            focus = .duration
            return
        }
        guard let battery = Int(draft.battery.trimmingCharacters(in: .whitespaces)),
              (minimumBattery...100).contains(battery)
        else {
            error = "Enter a battery percentage from \(minimumBattery) to 100."
            focus = .battery
            return
        }
        save(SessionLimits(minutes: minutes, heat: draft.heat, battery: battery))
    }
}
