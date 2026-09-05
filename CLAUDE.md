# Allarise

Allarise is an iOS alarm app that integrates with Home Assistant over MQTT. The
Xcode project and bundle ID still carry the older "HaWake Alarm V2" name;
"Allarise" is the product name. Both refer to the same app.

This is the public mirror of the app's source. It is exported from the
private development repository as a snapshot, so its history is a series of
sync commits, not the original commit-by-commit history.

## Product principles

- Alarms must remain dependable and understandable.
- No analytics, tracking, or external data collection without explicit
  opt-in consent from the user.
- Prefer local and on-device behavior where practical.
- Wake-up challenges must be accessible and recoverable.
- Never weaken alarm reliability merely to simplify implementation.

## Backwards compatibility

Do not make breaking changes to the MQTT contract or the Home Assistant
integration. People have alarms configured, and automations, scripts and
dashboards built against it. Treat these as a published API:

- MQTT payload keys and shapes
- Home Assistant service names and their field names
- MQTT alarm indexes (entity ids are keyed on them)
- Persisted keys: UserDefaults, iCloud KV, SwiftData property names

Add fields, never replace them. Keep validation permissive. Fail soft when the
other side is older.

## Technology

- Swift and SwiftUI. Follow the architecture already in the repository.
- Prefer Apple-native frameworks where they provide the required capability.
- Do not introduce a new dependency without explaining why it is needed.

## Layout

| Location | Holds |
|---|---|
| `HaWake Alarm V2/` | All app source (file-system synchronized Xcode group) |
| `HaWake Alarm V2/Siri/` | App Intents, shortcuts |
| `HaWake Alarm V2Tests/` | Unit tests (XCTest and Swift Testing) |
| `HaWake Alarm V2UITests/` | UI tests |
| `BuiltInPresets/` | Bundled wallpaper presets |
| `tools/` | Dev and automation scripts |

Never create Swift files at the repo root; they need manual pbxproj wiring.

## Adding a stored property to `Alarm`

A new field must be classified in `Alarm.duplicate(label:alarmIndex:)` and
registered in `AlarmDuplicationTests.swift`, or duplication silently drops it.
Then check the other transport paths (MQTT, force-kill recovery, AlarmKit, Siri).

## Build

```bash
xcodebuild -project "HaWake Alarm V2.xcodeproj" -scheme "HaWake Alarm V2" \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Tests use `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` with
`build-for-testing` / `test-without-building`.

Firebase (analytics and product-update push, both opt-in) is disabled unless a
`GoogleService-Info.plist` is present in `HaWake Alarm V2/`. The app builds and
runs without it. Set your own development team in Xcode's Signing settings.

## Related repos

- Home Assistant integration: https://github.com/domoretechnet/allarise-hacs
- Documentation and site: https://allarise.app
