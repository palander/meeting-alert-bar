import AppKit
import EventKit

/// Manages the NSStatusItem, live countdown display, flash alert, and dropdown menu.
final class MenuBarController: NSObject {

    // MARK: - Properties

    private let statusItem: NSStatusItem
    private let calendarManager: CalendarManager

    private var countdownTimer: Timer?
    private var refreshTimer: Timer?
    private var flashTimer: Timer?
    private var isFlashInverted = false

    // Time font is fixed: monospaced digits at the default menu bar size so the
    // clock pixel-width never shifts as digits change.
    private let timeFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    // Title font is a computed property so it immediately reflects the user's
    // chosen size without needing to restart the app.
    private var titleFont: NSFont {
        NSFont.menuBarFont(ofSize: titleFontSize)
    }

    // MARK: - Persisted appearance settings

    /// Title font size in points. Default: 10 pt (one step smaller than the time).
    private var titleFontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "titleFontSize")
            return stored > 0 ? CGFloat(stored) : 10
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "titleFontSize")
        }
    }

    /// Extra horizontal padding added on top of the base 4 pt. Default: 6 pt.
    private var extraPadding: CGFloat {
        get {
            let key = "barExtraPadding"
            guard UserDefaults.standard.object(forKey: key) != nil else { return 6 }
            return CGFloat(UserDefaults.standard.double(forKey: key))
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "barExtraPadding")
        }
    }

    /// How many seconds before the meeting starts the flash alert kicks in. Default: 10 min.
    private var flashThreshold: TimeInterval {
        get {
            let key = "flashThresholdSeconds"
            guard UserDefaults.standard.object(forKey: key) != nil else { return 600 }
            return UserDefaults.standard.double(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "flashThresholdSeconds")
        }
    }

    // MARK: - Init / Deinit

    override init() {
        // Create with variableLength first so we can call instance methods to
        // compute the correct fixed width after super.init().
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        calendarManager = CalendarManager()
        super.init()

        statusItem.length = computeFixedWidth()

        setupButton()
        setupMenu()

        calendarManager.onEventStoreChanged = { [weak self] in
            self?.refreshEvents()
        }

        calendarManager.requestAccess { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startTimers()
                    self?.refreshEvents()
                } else {
                    self?.setButton(title: "No Calendar Access", countdown: nil, flashCountdown: false)
                }
            }
        }
    }

    deinit {
        countdownTimer?.invalidate()
        refreshTimer?.invalidate()
        flashTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupButton() {
        statusItem.button?.title = "Loading…"
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // --- Event details ---
        let titleItem = NSMenuItem(title: "No upcoming events", action: nil, keyEquivalent: "")
        titleItem.tag = 1
        menu.addItem(titleItem)

        let timeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        timeItem.tag = 2
        menu.addItem(timeItem)

        let locationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        locationItem.tag = 3
        locationItem.isHidden = true
        menu.addItem(locationItem)

        menu.addItem(.separator())

        // --- Configuration ---
        let calendarsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        calendarsItem.tag = 10
        calendarsItem.submenu = NSMenu()
        menu.addItem(calendarsItem)

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.tag = 11
        appearanceItem.submenu = NSMenu()
        menu.addItem(appearanceItem)

        // --- Actions ---
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshEvents), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Meeting Alert Bar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Timers

    private func startTimers() {
        countdownTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDisplay()
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)

        refreshTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshEvents()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    // MARK: - Event Refresh

    @objc private func refreshEvents() {
        calendarManager.fetchNextEvent { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuItems()
                self?.updateDisplay()
            }
        }
    }

    // MARK: - Menu Item Updates

    private func updateMenuItems() {
        guard let menu = statusItem.menu else { return }

        if let event = calendarManager.nextEvent {
            menu.item(withTag: 1)?.title = event.title ?? "Untitled Event"
            menu.item(withTag: 2)?.title = formattedDateTime(event.startDate)

            if let location = event.location, !location.isEmpty {
                menu.item(withTag: 3)?.title = "📍 \(location)"
                menu.item(withTag: 3)?.isHidden = false
            } else {
                menu.item(withTag: 3)?.title = ""
                menu.item(withTag: 3)?.isHidden = true
            }
        } else {
            menu.item(withTag: 1)?.title = "No upcoming events"
            menu.item(withTag: 2)?.title = ""
            menu.item(withTag: 3)?.isHidden = true
        }
    }

    private func formattedDateTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - Calendars Submenu

    private func updateCalendarsSubmenu() {
        guard let parentItem = statusItem.menu?.item(withTag: 10) else { return }

        let submenu = NSMenu()
        let allCalendars = calendarManager.availableCalendars()
        let selected = calendarManager.selectedCalendarIDs()

        for calendar in allCalendars {
            let item = NSMenuItem(
                title: calendar.title,
                action: #selector(toggleCalendar(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = calendar.calendarIdentifier
            item.state = selected.contains(calendar.calendarIdentifier) ? .on : .off
            item.image = colorDot(calendar.color)
            submenu.addItem(item)
        }

        parentItem.submenu = submenu
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var selected = calendarManager.selectedCalendarIDs()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        calendarManager.setSelectedCalendarIDs(selected)
        refreshEvents()
    }

    // MARK: - Appearance Submenu

    private func updateAppearanceSubmenu() {
        guard let parentItem = statusItem.menu?.item(withTag: 11) else { return }

        let submenu = NSMenu()

        // ── Title Size ──
        submenu.addItem(sectionHeader("Title Size"))

        let fontSizes: [(label: String, pt: CGFloat)] = [
            ("X-Small",  9),
            ("Small",   10),
            ("Default", 11),
            ("Large",   12),
            ("X-Large", 13),
        ]
        for option in fontSizes {
            let item = NSMenuItem(
                title: "\(option.label)  (\(Int(option.pt)) pt)",
                action: #selector(setTitleFontSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: Double(option.pt))
            item.state = titleFontSize == option.pt ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        // ── Flash Alert ──
        submenu.addItem(sectionHeader("Flash Alert Before Meeting"))

        let thresholds: [(label: String, seconds: TimeInterval)] = [
            ("2 minutes",   120),
            ("5 minutes",   300),
            ("10 minutes",  600),
            ("15 minutes",  900),
            ("20 minutes", 1200),
            ("30 minutes", 1800),
        ]
        for option in thresholds {
            let item = NSMenuItem(
                title: option.label,
                action: #selector(setFlashThreshold(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: option.seconds)
            item.state = flashThreshold == option.seconds ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        // ── Bar Width ──
        submenu.addItem(sectionHeader("Bar Width"))

        let widths: [(label: String, padding: CGFloat)] = [
            ("Tight",     0),
            ("Default",   6),
            ("Relaxed",  14),
            ("Wide",     24),
        ]
        for option in widths {
            let item = NSMenuItem(
                title: option.label,
                action: #selector(setBarWidth(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: Double(option.padding))
            item.state = extraPadding == option.padding ? .on : .off
            submenu.addItem(item)
        }

        parentItem.submenu = submenu
    }

    /// A disabled, indented label used as a visual section header inside a submenu.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuBarFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    @objc private func setTitleFontSize(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        titleFontSize = CGFloat(value)
        applyAppearanceChange()
    }

    @objc private func setBarWidth(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        extraPadding = CGFloat(value)
        applyAppearanceChange()
    }

    @objc private func setFlashThreshold(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        flashThreshold = value
    }

    /// Recomputes the status item width and redraws with updated fonts.
    private func applyAppearanceChange() {
        statusItem.length = computeFixedWidth()
        // Redraw immediately so the user sees the effect without waiting for the next tick.
        updateDisplay()
    }

    // MARK: - Status Bar Display

    private func updateDisplay() {
        guard let event = calendarManager.nextEvent else {
            stopFlashing()
            setButton(title: "No events", countdown: nil, flashCountdown: false)
            return
        }

        let remaining = event.startDate.timeIntervalSince(Date())

        guard remaining > 0 else {
            refreshEvents()
            return
        }

        let (title, countdown) = buildStatusParts(for: event, remaining: remaining)

        if remaining < flashThreshold {
            startFlashing(title: title, countdown: countdown)
        } else {
            stopFlashing()
            setButton(title: title, countdown: countdown, flashCountdown: false)
        }
    }

    private func buildStatusParts(for event: EKEvent, remaining: TimeInterval) -> (title: String, countdown: String) {
        let raw = event.title ?? "Untitled"

        // Truncate at the last complete word that fits within 15 characters,
        // so "Lari / Sally Review" becomes "Lari / Sally… " rather than "Lari / Sally Re… ".
        let prefix: String
        let separator: String
        if raw.count <= 15 {
            prefix = raw
            separator = " "
        } else {
            let head = String(raw.prefix(15))
            if let lastSpace = head.lastIndex(of: " "),
               lastSpace > head.startIndex {
                // Trim any trailing punctuation/spaces before the ellipsis.
                prefix = String(head[..<lastSpace])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                // No word boundary in the first 15 chars — fall back to hard cut.
                prefix = head
            }
            separator = " "
        }

        let countdown: String
        if remaining >= 3600 {
            let h = Int(remaining) / 3600
            let m = (Int(remaining) % 3600) / 60
            countdown = "\(h)h \(m)m"
        } else {
            let m = Int(remaining) / 60
            let s = Int(remaining) % 60
            countdown = String(format: "%02d:%02d", m, s)
        }

        return (prefix + separator, countdown)
    }

    // MARK: - Flash Effect

    private func startFlashing(title: String, countdown: String) {
        guard flashTimer == nil else { return }

        flashTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.isFlashInverted.toggle()

            let (liveTitle, liveCountdown): (String, String)
            if let ev = self.calendarManager.nextEvent {
                let r = ev.startDate.timeIntervalSince(Date())
                (liveTitle, liveCountdown) = r > 0
                    ? self.buildStatusParts(for: ev, remaining: r)
                    : (title, countdown)
            } else {
                (liveTitle, liveCountdown) = (title, countdown)
            }
            self.setButton(title: liveTitle, countdown: liveCountdown, flashCountdown: self.isFlashInverted)
        }
        RunLoop.main.add(flashTimer!, forMode: .common)
        setButton(title: title, countdown: countdown, flashCountdown: false)
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        isFlashInverted = false
    }

    // MARK: - Button Rendering

    private func setButton(title: String, countdown: String?, flashCountdown: Bool) {
        guard let button = statusItem.button else { return }

        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: titleFont]
        )

        if let countdown {
            var timeAttrs: [NSAttributedString.Key: Any] = [.font: timeFont]
            if flashCountdown { timeAttrs[.foregroundColor] = NSColor.systemRed }
            result.append(NSAttributedString(string: countdown, attributes: timeAttrs))
        }

        button.attributedTitle = result
    }

    // MARK: - Fixed-Width Calculation

    /// Uses "n" × 17 (title + separator) as a realistic average-width worst case
    /// instead of "W" × 17, which is far too conservative and produces excess space.
    /// The base is 4 pt; `extraPadding` is added by the user's Width setting.
    private func computeFixedWidth() -> CGFloat {
        let maxTitle = String(repeating: "n", count: 17) // 15 chars + "… "
        let titleW = (maxTitle as NSString).size(withAttributes: [.font: titleFont]).width

        let maxTime = "9h 59m"
        let timeW = (maxTime as NSString).size(withAttributes: [.font: timeFont]).width

        return ceil(titleW + timeW) + 4 + extraPadding
    }

    // MARK: - Helpers

    private func colorDot(_ color: NSColor) -> NSImage {
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.withAlphaComponent(1.0).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateCalendarsSubmenu()
        updateAppearanceSubmenu()
    }
}
