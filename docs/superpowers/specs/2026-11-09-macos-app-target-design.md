# SievePilot macOS App Target Design

**Date:** 2026-11-09

## Intent

Add the runnable native macOS application shell required by the approved SievePilot product design. The target gives developers an Xcode project they can open, build, and run while preserving `SievePilotCore` as the independently tested engine.

## Goals

- Commit `SievePilot.xcodeproj` with a native macOS application target named `SievePilot`.
- Target macOS 13 or newer.
- Use SwiftUI `MenuBarExtra` as an accessory-style menu-bar application.
- Link the existing local `SievePilotCore` Swift package product.
- Provide a minimal menu showing the product name, core-engine status, and a Quit action.
- Add an application test target for the small amount of app-owned presentation state where practical.
- Keep `swift test` working for the package and make the app buildable with `xcodebuild` when full Xcode is installed.

## Non-goals

- ManageSieve networking, account setup, credentials, Keychain access, settings, or out-of-office editing UI.
- Signing, notarization, release automation, or Apple Developer credentials.
- Moving core-engine source files into the Xcode project.
- Introducing external dependencies or a project generator.

## Constraints

- The current machine does not have full Xcode installed, so project structure and Swift package tests can be verified locally, but the final Xcode application build must be verified after Xcode installation.
- The app must have no Dock icon and no ordinary main window in this phase.
- The package remains the source of truth for `SievePilotCore` and its tests.

## Approaches

### Selected: committed Xcode macOS application project

Create a conventional `.xcodeproj` containing an application target and unit-test target, with the repository’s local Swift package linked as a package dependency. This provides proper application bundle metadata, deployment settings, signing configuration points, and future entitlement support.

### Rejected: SwiftPM executable target

This would require fewer files but would not provide the appropriate long-term app bundle, signing, entitlement, and distribution structure.

## Structure

- `SievePilot.xcodeproj/` — project and shared scheme.
- `SievePilotApp/SievePilotApp.swift` — SwiftUI application entry point using `MenuBarExtra`.
- `SievePilotApp/AppModel.swift` — minimal app-owned presentation state, importing `SievePilotCore` to verify linkage.
- `SievePilotApp/Assets.xcassets/` — application asset catalog.
- `SievePilotAppTests/` — focused tests for app-owned state.

The menu-bar scene will display a simple placeholder such as:

```text
SievePilot
Core engine ready
──────────────
Quit SievePilot
```

The application will use accessory activation behavior so it appears only in the menu bar. Future UI and transport plans can extend this target without changing the core package boundary.

## Verification

- Run the existing `swift test` package suite.
- Inspect the project with tools available without Xcode and validate committed project references.
- Run `xcodebuild -list -project SievePilot.xcodeproj` and the app tests once full Xcode is installed; this is an explicit environmental verification gap until then.
