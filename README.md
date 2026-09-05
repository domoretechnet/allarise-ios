# Allarise

An iOS alarm app built for reliability, with wake-up missions, sleep sounds,
internet radio alarms, and a deep [Home Assistant](https://www.home-assistant.io)
integration over MQTT.

- App Store: https://apps.apple.com/app/id6760920796
- Documentation: https://allarise.app
- Home Assistant integration (HACS): https://github.com/domoretechnet/allarise-hacs

## About this repository

This is the public mirror of the Allarise iOS source. It is exported as
snapshots from the private development repository, so the history here is a
series of sync commits. Issues and pull requests are welcome; accepted changes
are applied to the private repository and flow back out in the next sync.

The Xcode project still carries the app's original working name, "HaWake
Alarm V2". It is the same app.

## Building

Open `HaWake Alarm V2.xcodeproj` in Xcode, select your own development team
under Signing & Capabilities, and run. Firebase-backed features (opt-in
analytics and product-update push) stay disabled unless you add your own
`GoogleService-Info.plist` to `HaWake Alarm V2/`.

Command line:

```bash
xcodebuild -project "HaWake Alarm V2.xcodeproj" -scheme "HaWake Alarm V2" \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## License

See [LICENSE](LICENSE). The Allarise name, icon and artwork are trademarks of
DoMore Tech LLC and are not covered by the source license.

Copyright © 2026 DoMore Tech LLC, a Michigan limited liability company.
