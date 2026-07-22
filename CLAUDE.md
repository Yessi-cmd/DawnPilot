# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test commands

```bash
# Regenerate Xcode project after editing project.yml
xcodegen generate

# Simulator build (no signing)
xcodebuild -project DawnPilot.xcodeproj -scheme DawnPilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/DawnPilot-Simulator-DerivedData \
  build CODE_SIGNING_ALLOWED=NO

# Run Swift tests
xcodebuild test -project DawnPilot.xcodeproj -scheme DawnPilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/DawnPilot-Tests-DerivedData \
  CODE_SIGNING_ALLOWED=NO

# Run a single test class or method
xcodebuild test -project DawnPilot.xcodeproj -scheme DawnPilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:DawnPilotTests/PrecipitationEvaluatorTests \
  CODE_SIGNING_ALLOWED=NO

# Unsigned Release device build
xcodebuild -project DawnPilot.xcodeproj -scheme DawnPilot \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/DawnPilot-Release-DerivedData \
  build CODE_SIGNING_ALLOWED=NO

# AltStore IPA package
./scripts/package-altstore.sh

# Server tests
python3 -m unittest discover -s server/tests -v

# Local server (requires DAWNPILOT_TOKEN set)
DAWNPILOT_TOKEN=dev-token DAWNPILOT_CACHE_FILE=/tmp/dawnpilot-cache.json \
  python3 server/dawnpilot_server.py
```

## Architecture

### Data flow

```
Open-Meteo → VPS (Python cache/proxy) → iPhone (SwiftUI app)
                                              ↓
                                   PrecipitationEvaluator
                                   (local rule engine)
                                              ↓
                                   AlarmCoordinator
                                   (AlarmKit scheduling)
```

The VPS fetches and normalizes weather. The iPhone **owns all decision logic**: it fetches the forecast from the VPS, evaluates precipitation rules locally, and schedules AlarmKit alarms accordingly. The VPS is a dumb cache; the app is the brain.

### Swift actor/model boundaries

- **`AppModel`** (`@MainActor`, `ObservableObject`) — UI-owned state: settings, status, alarm records, authorization text. Views read from it; user actions call its methods which delegate to `AlarmCoordinator`.
- **`AlarmCoordinator`** (`actor`) — sole owner of AlarmKit mutations and `ManagedAlarmRecord` persistence. Views must never bypass it. It reads/writes records through `SettingsStore` and schedules/cancels alarms through `AlarmManager.shared`.
- **`SettingsStore`** (enum with static methods) — Codable persistence layer over `UserDefaults` with ISO 8601 date coding. Three keys: settings, records, status. Treat stored Codable changes as migrations.
- **`WeatherService`** (`Sendable` struct) — stateless HTTP client that fetches `ServerForecast` from the VPS.
- **`PrecipitationEvaluator`** (enum with static `evaluate`) — pure function: takes a forecast + settings → returns `WeatherEvaluation`. No side effects, no AlarmKit/UI dependencies — intentionally testable in isolation.
- **`CurrentLocationService`** (`@MainActor` class) — one-shot Core Location + reverse geocoding. Not continuous tracking.

### Alarm lifecycle invariants

1. **At most one managed record per date key** (formatted as `YYYY-MM-DD` in the user's calendar timezone).
2. **Schedule new before canceling old** — `replaceRecord` creates the new alarm first, then cancels the old one. If cancellation fails, the new alarm is rolled back.
3. **Weather failure preserves the last valid alarm** — never delete tomorrow's alarm just because networking/parsing failed. Falls back to: existing weather-based alarm > existing fallback alarm > new fallback alarm.
4. **14-day fallback horizon** — `ensureFallbackHorizon` maintains one-off fallback alarms for every enabled weekday in the next 14 days. These are replaced by weather-based alarms when refresh succeeds.
5. **Manual override origin** — if the user refreshes on a non-enabled weekday, the alarm is marked `.manualOverride` and survives weekday-disabled cleanup.

### Precipitation evaluation rules

- Forecast window is **half-open**: start ≤ hour < end.
- A forecast hour is "rainy" if **any** of: precipitation probability ≥ threshold, precipitation ≥ 0.1 mm, or WMO precipitation weather code (drizzle/rain/snow/showers/thunderstorm ranges).
- Forecast older than 6 hours → `forecastTooOld` error.
- Zero matching hours in the target window → `missingTargetHours` error.

### Project configuration

- **`project.yml`** is the source of truth for targets, build settings, bundle IDs, and Info.plist properties. Never hand-edit `DawnPilot.xcodeproj/project.pbxproj`.
- After changing `project.yml`, run `xcodegen generate` and commit the regenerated project.
- Bundle ID: `com.yessicmd.dawnpilot`. Background refresh ID: `com.yessicmd.dawnpilot.refresh`.
- Deployment target: iOS 26.0. Swift 5.9. No third-party Swift dependencies.

### Server (Python)

- Zero dependencies beyond Python 3.11 stdlib. Runs on `127.0.0.1:8787` behind a reverse proxy (Caddy/nginx).
- `GET /healthz` — public. `GET /v1/forecast` — Bearer token auth with constant-time comparison.
- 15-minute request cache, 30-minute background refresh. Serves stale data on upstream failure.
- Cache writes are atomic (write to `.tmp`, then `replace`). Cache file must be mode `0600`.
- Schema version `1` — changing the normalized forecast shape requires coordinated Swift + Python updates.

### Key calendars and timezones

- Always use `AppSettings.calendar` (Gregorian, user's IANA timezone, `zh_CN` locale) for date/weekday/alarm calculations. Never use the process timezone for scheduling logic.
- Date keys use the settings calendar, not the system calendar.

### Testing patterns

- `PrecipitationEvaluatorTests` — deterministic rule tests (probability thresholds, precipitation amounts, WMO codes, stale data, missing hours, timezone boundaries).
- `WeatherProtocolTests` — JSON decoding of the server's normalized forecast shape.
- `AppSettingsMigrationTests` — Codable backward compatibility.
- `AlarmRefreshTriggerTests` — trigger origin logic for enabled vs non-enabled weekdays.
- Test without AlarmKit/UI dependencies where possible. The evaluator and protocol tests are pure logic.
