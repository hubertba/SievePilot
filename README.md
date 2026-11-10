# SievePilot

A native open-source macOS menu-bar application for managing server-side Sieve email automation.

The first planned feature is an out-of-office rule with reliable server-side expiry. Future features may include server-side folder sorting.

## Status

The core Sieve rule engine and initial macOS menu-bar app shell are implemented. See [the design](docs/superpowers/specs/2026-04-24-sievepilot-design.md), [the core-engine plan](docs/superpowers/plans/2026-11-08-sievepilot-core-engine.md), and [the app-target design](docs/superpowers/specs/2026-11-09-macos-app-target-design.md).

The bounded ManageSieve parser and transport-independent protocol engine are implemented and tested with deterministic fake transports. Live TCP/TLS connections, account setup, and credential loading from `.env` files or Keychain remain deferred; the app does not yet connect to a ManageSieve server.

## Development

Open the native macOS project in Xcode:

```bash
open SievePilot.xcodeproj
```

Run the core package tests:

```bash
swift test
```

With full Xcode installed, build the app and run its tests:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'
```
