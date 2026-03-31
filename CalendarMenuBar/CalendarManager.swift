import EventKit
import Foundation

/// Wraps EKEventStore to request authorization and fetch the next upcoming event.
///
/// Google Calendar events appear here once the Google account is connected in
/// System Settings → Internet Accounts → Google (Calendars enabled). No OAuth
/// or API keys are required — EventKit reads the locally-synced data.
final class CalendarManager {

    // MARK: - Properties

    private let store = EKEventStore()

    /// The most recently fetched next upcoming event. Set by fetchNextEvent(_:).
    private(set) var nextEvent: EKEvent?

    /// Called on the main thread when the event store changes (e.g., after a Google sync).
    var onEventStoreChanged: (() -> Void)?

    // MARK: - Init / Deinit

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEventStoreChange),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Authorization

    /// Requests calendar read access. Calls completion immediately if already granted.
    /// Completion may arrive on any thread — callers must dispatch to main if needed.
    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess {
                completion(true)
                return
            }
            store.requestFullAccessToEvents { granted, _ in
                completion(granted)
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .authorized {
                completion(true)
                return
            }
            store.requestAccess(to: .event) { granted, _ in
                completion(granted)
            }
        }
    }

    // MARK: - Calendar Selection

    /// All event calendars available on this machine, sorted alphabetically by title.
    func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The set of calendar identifiers the user has chosen to show.
    /// If the user has never configured a selection, returns all available IDs (show everything).
    func selectedCalendarIDs() -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: "selectedCalendarIDs") {
            return Set(saved)
        }
        // First launch — default to all calendars selected.
        return Set(store.calendars(for: .event).map { $0.calendarIdentifier })
    }

    /// Persists the calendar selection to UserDefaults.
    func setSelectedCalendarIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: "selectedCalendarIDs")
    }

    // MARK: - Fetching

    /// Asynchronously fetches the next non-all-day event in the selected calendars (up to 7 days out).
    /// Updates `nextEvent` and calls `completion` on a background thread.
    func fetchNextEvent(_ completion: @escaping (EKEvent?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Resolve which calendars to search.
            let cals = self.calendarsForFetch()

            // If the user explicitly deselected everything, return no event immediately.
            if let cals, cals.isEmpty {
                self.nextEvent = nil
                completion(nil)
                return
            }

            let now = Date()
            let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!

            let predicate = self.store.predicateForEvents(
                withStart: now,
                end: horizon,
                calendars: cals   // nil = search all calendars
            )

            let events = self.store.events(matching: predicate)

            let next = events
                .filter { !$0.isAllDay && $0.startDate > now }
                .min(by: { $0.startDate < $1.startDate })

            self.nextEvent = next
            completion(next)
        }
    }

    // MARK: - Private

    /// Returns the EKCalendar objects to pass to the event predicate, or nil to search all.
    /// Returns an empty array if the user has a saved selection that maps to zero known calendars.
    private func calendarsForFetch() -> [EKCalendar]? {
        // No UserDefaults entry → user hasn't configured; search everything.
        guard UserDefaults.standard.object(forKey: "selectedCalendarIDs") != nil else {
            return nil
        }
        let saved = Set(UserDefaults.standard.stringArray(forKey: "selectedCalendarIDs") ?? [])
        let all = store.calendars(for: .event)
        return all.filter { saved.contains($0.calendarIdentifier) }
    }

    @objc private func handleEventStoreChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.onEventStoreChanged?()
        }
    }
}
