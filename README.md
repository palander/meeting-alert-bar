# CalendarMenuBar

A native macOS menu bar app that shows your next upcoming Google Calendar event with a live countdown timer. No API keys, no OAuth — it reads events through EventKit from your locally-synced macOS Calendars.

## What it looks like

```
Staff meeting… 1h 42m       ← normal state (≥ 1 hour)
Staff meeting… 08:34        ← countdown in mm:ss (< 1 hour)
Staff meeting… 08:34        ← flashes red (< 10 minutes)
```

Clicking the menu bar item shows:

```
Staff meeting
Mar 28, 2024 at 2:00 PM
📍 Conference Room B

Refresh
──────
Quit CalendarMenuBar
```

## Requirements

- macOS 13.0+
- Xcode 15+
- An Apple Developer account (free tier is fine — needed to sign the app so it can access calendars)
- A Google account added in macOS System Settings with Calendars enabled

## Setup

### Step 1 — Connect Google Calendar to macOS

1. Open **System Settings** → **Internet Accounts**
2. Click **Add Account** → **Google**
3. Sign in and make sure **Calendars** is toggled on
4. Open the **Calendar** app — your Google events should appear within a minute or two

### Step 2 — Build in Xcode

1. Open `CalendarMenuBar.xcodeproj`
2. In the Project navigator, select the **CalendarMenuBar** target
3. Under **Signing & Capabilities**, set your **Team** (any Apple ID works)
4. Optionally change `PRODUCT_BUNDLE_IDENTIFIER` in Build Settings to something unique (e.g. `com.yourname.calendarmenubar`)
5. Press **⌘R** to build and run

On first launch macOS will prompt for calendar access — click **Allow**.

### Step 3 — Run at Login (optional)

For permanent use, export a release build:

1. Product → Archive → Distribute App → Copy App
2. Move `CalendarMenuBar.app` to `/Applications`
3. System Settings → General → Login Items → add `CalendarMenuBar.app`

## Project structure

```
CalendarMenuBar/
├── CalendarMenuBar.xcodeproj/
│   └── project.pbxproj          # Xcode project (targets macOS 13+)
├── CalendarMenuBar/
│   ├── main.swift                # Entry point — creates NSApplication
│   ├── AppDelegate.swift         # App lifecycle
│   ├── MenuBarController.swift   # Status item, timers, flash effect, menu
│   ├── CalendarManager.swift     # EventKit access + event fetching
│   ├── Info.plist                # LSUIElement=YES (no Dock icon)
│   └── CalendarMenuBar.entitlements  # com.apple.security.personal-information.calendars
└── README.md
```

## How it works

| Concern | Implementation |
|---|---|
| Calendar data | `EKEventStore` reads events synced by macOS — no Google API needed |
| Countdown | `Timer` fires every second on `.common` RunLoop mode (works while menu is open) |
| Auto-refresh | Second `Timer` re-fetches events every 60 s |
| Sync reaction | Observes `EKEventStoreChanged` notification to catch live Google syncs |
| Flash alert | `Timer` at 0.5 s alternates `NSAttributedString` foreground between system default and `systemRed` |
| No Dock icon | `LSUIElement = YES` in Info.plist + `setActivationPolicy(.accessory)` |

## Troubleshooting

**"No events" even though I have calendar events**
- Confirm the Google account appears in System Settings → Internet Accounts with Calendars enabled
- Open Calendar.app and check the events are visible there
- Click **Refresh** in the menu bar dropdown
- Check System Settings → Privacy & Security → Calendars — make sure CalendarMenuBar is listed and allowed

**Calendar permission dialog never appeared**
- Reset the permission: `tccutil reset Calendars com.example.calendarmenubar` in Terminal, then relaunch

**Build error: "No account for team"**
- Sign in to your Apple ID in Xcode → Settings → Accounts, then set the Team in Signing & Capabilities
