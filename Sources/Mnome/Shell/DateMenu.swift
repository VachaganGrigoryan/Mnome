import AppKit
import SwiftUI
import EventKit
import MnomeSupport

/// The day's events from Calendar. Access is asked for the first time the date menu opens.
@MainActor final class Agenda: ObservableObject {
    struct Event: Identifiable { let id: String, title: String, time: String, color: Color }
    @Published private(set) var events: [Event] = []
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()
    private var day = Date(), watching: NSObjectProtocol?
    private let preview: Bool
    /// `preview`: no events and no access request, for the gallery.
    init(preview: Bool = false) { self.preview = preview; if preview { access = .fullAccess } }
    func show(_ day: Date) {
        self.day = day
        guard !preview else { return }
        if access == .notDetermined { Task { _ = try? await store.requestFullAccessToEvents(); access = EKEventStore.authorizationStatus(for: .event); load() } } else { load() }
        if watching == nil { watching = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in Task { @MainActor in self?.load() } } }
    }
    private func load() {
        guard access == .fullAccess, let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day)) else { events = []; return }
        let time = DateFormatter(); time.setLocalizedDateFormatFromTemplate("jm")
        events = store.events(matching: store.predicateForEvents(withStart: Calendar.current.startOfDay(for: day), end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }.map {
            Event(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "", time: $0.isAllDay ? "All Day" : time.string(from: $0.startDate), color: Color(nsColor: $0.calendar.color))
        }
    }
}

struct DateMenuView: View {
    @ObservedObject var agenda: Agenda
    /// Fixed for the gallery; now otherwise.
    var at: Date?
    @State private var today = Date()
    @State private var month = Date()
    @State private var selected = Date()
    private let calendar = Calendar.current
    private func text(_ template: String, _ date: Date) -> String { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate(template); return f.string(from: date) }
    var body: some View {
        MenuBox(radius: 30, padding: 12) {
            HStack(alignment: .top, spacing: 0) {
                messages.frame(width: 410)
                Rectangle().fill(ShellPalette.ink(0.1)).frame(width: 1).padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 12) {
                    Button { month = today; select(today) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text("EEEE", today)).font(.adwaita(14.667, .bold)).foregroundStyle(ShellPalette.dim)
                            Text(text("yMMMMd", today)).font(.adwaita(20, .heavy)).foregroundStyle(ShellPalette.dim)
                        }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(ShellButtonStyle(radius: 12)).accessibilityLabel("Today, \(text("EEEEyMMMMd", today))")
                    grid
                    events
                }.frame(width: 280)
            }
        }
        .onAppear { today = at ?? Date(); month = today; select(today) }
        .onExitCommand {}
    }
    private func select(_ day: Date) { selected = day; agenda.show(day) }
    @ObservedObject private var spaces = SpacesWatch.shared
    private var messages: some View {
        VStack(spacing: 12) {
            if let summary = spaces.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra Mac Desktops").font(.adwaita(14.667, .bold))
                    Text(summary + " Remove them in Preferences → Shell.").font(.adwaita(13)).foregroundStyle(ShellPalette.ink(0.7)).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(ShellPalette.ink(0.08)))
            }
            Spacer()
            if spaces.summary == nil { Image(systemName: "bell.slash").font(.system(size: 48, weight: .regular)).foregroundStyle(ShellPalette.ink(0.4)).accessibilityHidden(true)
            Text("No Notifications").font(.adwaita(14.667, .bold)).foregroundStyle(ShellPalette.ink(0.5)) }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var grid: some View {
        let model = MonthGrid(month: month, today: today, calendar: calendar)
        return VStack(spacing: 0) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }.buttonStyle(ShellButtonStyle()).accessibilityLabel("Previous month")
                Text(model.title).font(.adwaita(14.667, .bold)).frame(maxWidth: .infinity)
                Button { month = calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }.buttonStyle(ShellButtonStyle()).accessibilityLabel("Next month")
            }.padding(.bottom, 6)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { ForEach(Array(model.weekdays.enumerated()), id: \.offset) { Text($1).font(.adwaita(12, .bold)).foregroundStyle(ShellPalette.dim).frame(width: 40, height: 28) } }
                ForEach(0..<6, id: \.self) { row in
                    GridRow { ForEach(model.days[row * 7..<row * 7 + 7], id: \.date) { day in dayButton(day) } }
                }
            }
        }
    }
    private func dayButton(_ day: MonthGrid.Day) -> some View {
        let chosen = calendar.isDate(day.date, inSameDayAs: selected) && !day.today
        return Button { if !day.inMonth { month = day.date }; select(day.date) } label: {
            Text(day.number).font(.adwaita(13, day.inMonth && !day.weekend || day.today ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(day.today ? Color.white : day.inMonth && !day.weekend ? ShellPalette.text : ShellPalette.dim)
                .frame(width: 36, height: 36).background(Circle().fill(day.today ? ShellPalette.toggleOn : chosen ? ShellPalette.ink(0.15) : .clear))
        }.buttonStyle(ShellButtonStyle()).frame(width: 40, height: 40).accessibilityLabel(text("EEEEyMMMMd", day.date)).accessibilityAddTraits(chosen || day.today ? .isSelected : [])
    }
    private var events: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calendar.isDate(selected, inSameDayAs: today) ? "Today" : text("EEEEMMMMd", selected)).font(.adwaita(14.667, .bold)).foregroundStyle(ShellPalette.dim)
            switch agenda.access {
            case .fullAccess:
                if agenda.events.isEmpty { Text("No Events").font(.adwaita(14.667).italic()).foregroundStyle(ShellPalette.dim) }
                ForEach(agenda.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(event.color).frame(width: 8, height: 8)
                        Text(event.title).font(.adwaita(14.667)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.time).font(.adwaita(13)).foregroundStyle(ShellPalette.dim).monospacedDigit()
                    }
                }
            case .notDetermined: Text("Asking for access to Calendar…").font(.adwaita(14.667).italic()).foregroundStyle(ShellPalette.dim)
            default:
                Button("Allow Mnome to read Calendar…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
                    .buttonStyle(.plain).font(.adwaita(14.667, .bold))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(ShellPalette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
