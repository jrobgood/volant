import AppKit
import EventKit
import VolantCore

struct EventEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let joinURL: URL?
    let calendar: String

}

/// Today's events, read-only, with a meeting link pulled from the event's URL, location or notes.
final class CalendarAgenda {
    private let store = EKEventStore()

    enum Outcome { case events([EventEntry]), denied }

    /// Events from now through the end of tomorrow, so a late-evening query still shows what is next.
    func upcoming(completion: @escaping (Outcome) -> Void) {
        ensureAccess { [weak self] granted in
            guard let self else { completion(.events([])); return }
            guard granted else { completion(.denied); return }
            let now = Date()
            let cal = Calendar.current
            let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(48 * 3600)
            let predicate = self.store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: nil)
            let events = self.store.events(matching: predicate)
                .filter { $0.endDate > now || $0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(14)
                .map { e in
                    EventEntry(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "(untitled)",
                               start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                               joinURL: CalendarAgenda.joinLink(e), calendar: e.calendar.title)
                }
            completion(.events(Array(events)))
        }
    }

    /// Only a link on a known meeting host, over https, counts as a join link. Anything else is not offered.
    static func joinLink(_ event: EKEvent) -> URL? {
        if let url = event.url, CalendarAgenda.isMeetingURL(url) { return url }
        let haystack = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: haystack, range: NSRange(haystack.startIndex..., in: haystack))
        return matches.compactMap(\.url).first(where: isMeetingURL)
    }

    static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co", "tuple.app", "meet.jit.si"]

    static func isMeetingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Opens a join link in its own handler, otherwise launches the user's calendar app rather than always Apple Calendar.
    static func open(_ entry: EventEntry, workspace: HandlerWorkspace = NSWorkspace.shared) {
        Task { @MainActor in
            if let url = entry.joinURL { try? await DefaultHandler.open(url, workspace: workspace) }
            else { try? await DefaultHandler.openCalendar(workspace: workspace) }
        }
    }

    private func ensureAccess(_ completion: @escaping (Bool) -> Void) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: completion(true)
        case .notDetermined:
            PermissionGate.begin()
            store.requestFullAccessToEvents { granted, _ in DispatchQueue.main.async { PermissionGate.end(); completion(granted) } }
        default: completion(false)
        }
    }
}
