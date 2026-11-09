# SievePilot

A native open-source macOS menu-bar application for managing server-side Sieve email automation.

The first planned feature is an out-of-office rule with reliable server-side expiry. Future features may include server-side folder sorting.

## Status

The core Sieve rule engine is under implementation. See [the design](docs/superpowers/specs/2026-04-24-sievepilot-design.md) and [the core-engine plan](docs/superpowers/plans/2026-11-08-sievepilot-core-engine.md).

Run the core test suite with:

```bash
swift test
```
