# SievePilot macOS App Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a committed Xcode project containing a runnable macOS 13+ SwiftUI menu-bar app that links the existing `SievePilotCore` package.

**Architecture:** Keep the core engine in its current Swift package. Add a conventional Xcode application target with a small app-owned model and `MenuBarExtra` scene, plus an XCTest target and a repository validation script that can check project structure without full Xcode.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, XCTest, Swift Package Manager, Xcode project format

**Spec:** `docs/superpowers/specs/2026-11-09-macos-app-target-design.md`

## Global Constraints

- Target macOS 13 or newer.
- Use SwiftUI `MenuBarExtra` and accessory application behavior with no Dock icon or ordinary main window.
- Link the local `SievePilotCore` package product; do not move core source into the app target.
- Add no external dependencies or project generator.
- Do not add signing credentials or secrets.
- Full `xcodebuild` verification remains unavailable until Xcode is installed; structural validation and `swift test` must run locally.

## Review Focus

- Missing or incorrect target membership must be caught by `Scripts/validate-xcode-project.sh` in Task 2.
- A project that references `SievePilotCore` but does not link its product must be caught by Task 2 validation.
- Missing `LSUIElement = YES`, which would produce a Dock icon, must be caught by Task 2 validation.
- Deployment targets below or above macOS 13 must be caught by Task 2 validation.
- A shared scheme that cannot discover both the app and app-test targets must be caught by Task 2 validation.

---

### Task 1: Add the menu-bar application source

**Files:**
- Create: `Scripts/validate-xcode-project.sh`
- Create: `SievePilotApp/AppModel.swift`
- Create: `SievePilotApp/SievePilotApp.swift`
- Create: `SievePilotApp/Assets.xcassets/Contents.json`
- Create: `SievePilotApp/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `SievePilotAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: public `SievePilotCore` module from the root package.
- Produces: `AppModel.productName: String`, `AppModel.coreStatus: String`, and the `SievePilotApp` SwiftUI entry point used by Task 2.

- [ ] **Step 1: Write the failing source-structure validator**

Create `Scripts/validate-xcode-project.sh` with a `sources` mode that fails unless the app entry point, model, asset catalog, and app-model XCTest file exist, and unless `SievePilotApp.swift` contains `MenuBarExtra`, `import SievePilotCore`, and `NSApplication.shared.terminate(nil)`.

- [ ] **Step 2: Run the validator to verify it fails**

Run: `bash Scripts/validate-xcode-project.sh sources`
Expected: FAIL because the application source files do not exist.

- [ ] **Step 3: Add the app model test and minimal model**

`SievePilotAppTests/AppModelTests.swift` must assert:

```swift
XCTAssertEqual(AppModel.productName, "SievePilot")
XCTAssertEqual(AppModel.coreStatus, "Core engine ready")
```

Implement those exact static properties in `SievePilotApp/AppModel.swift`.

- [ ] **Step 4: Add the SwiftUI menu-bar entry point and asset metadata**

Implement `@main struct SievePilotApp: App` with a `MenuBarExtra("SievePilot", systemImage: "line.3.horizontal.decrease.circle")` containing the product name, core status, a divider, and a `Quit SievePilot` button that calls `NSApplication.shared.terminate(nil)`. Use `.menuBarExtraStyle(.window)` and create valid empty asset-catalog metadata for the catalog and app-icon set.

- [ ] **Step 5: Run source validation**

Run: `bash Scripts/validate-xcode-project.sh sources`
Expected: PASS with `Validated SievePilot app sources`.

- [ ] **Step 6: Verify the existing package remains green**

Run: `. "$HOME/.swiftly/env.sh" && swift test`
Expected: all existing package tests pass.

- [ ] **Step 7: Commit**

```bash
git add Scripts SievePilotApp SievePilotAppTests
git commit -m "feat: add SievePilot menu bar app shell"
```

### Task 2: Add and validate the Xcode project

**Files:**
- Modify: `Scripts/validate-xcode-project.sh`
- Create: `SievePilot.xcodeproj/project.pbxproj`
- Create: `SievePilot.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- Create: `SievePilot.xcodeproj/xcshareddata/xcschemes/SievePilot.xcscheme`

**Interfaces:**
- Consumes: app and test sources from Task 1 and package product `SievePilotCore` at repository root.
- Produces: Xcode targets `SievePilot` and `SievePilotAppTests`, and shared scheme `SievePilot`.

- [ ] **Step 1: Extend the validator with failing project assertions**

Add a `project` mode that first runs `sources`, then fails unless:

- `plutil -lint SievePilot.xcodeproj/project.pbxproj` succeeds;
- the project defines native targets `SievePilot` and `SievePilotAppTests`;
- app source and asset files belong to the app target;
- `AppModelTests.swift` belongs to the test target;
- the root local package reference and `SievePilotCore` product dependency exist and are linked by the app target;
- `MACOSX_DEPLOYMENT_TARGET = 13.0`, `GENERATE_INFOPLIST_FILE = YES`, and `INFOPLIST_KEY_LSUIElement = YES` exist for the app target;
- `PRODUCT_BUNDLE_IDENTIFIER = com.hubertba.SievePilot` and test identifier `com.hubertba.SievePilotTests` exist;
- the shared scheme references both target identifiers.

- [ ] **Step 2: Run project validation to verify it fails**

Run: `bash Scripts/validate-xcode-project.sh project`
Expected: FAIL because `SievePilot.xcodeproj` does not exist.

- [ ] **Step 3: Create the Xcode project and shared scheme**

Create a conventional object-version-compatible `project.pbxproj` with app and unit-test native targets, Debug and Release configurations, source/resource/framework phases, the local `XCLocalSwiftPackageReference` for `.`, and `XCSwiftPackageProductDependency` for `SievePilotCore`. Configure the test target host as `$(BUILT_PRODUCTS_DIR)/SievePilot.app/Contents/MacOS/SievePilot`.

- [ ] **Step 4: Run project validation**

Run: `bash Scripts/validate-xcode-project.sh project`
Expected: PASS with `Validated SievePilot Xcode project`.

- [ ] **Step 5: Run Xcode discovery when available**

Run:

```bash
if xcode-select -p 2>/dev/null | grep -q 'Xcode.app'; then
  xcodebuild -list -project SievePilot.xcodeproj
else
  echo 'SKIP: full Xcode is not installed'
fi
```

Expected on this machine: `SKIP: full Xcode is not installed`. With Xcode installed: output lists both targets and the shared `SievePilot` scheme.

- [ ] **Step 6: Commit**

```bash
git add Scripts/validate-xcode-project.sh SievePilot.xcodeproj
git commit -m "build: add SievePilot Xcode project"
```

### Task 3: Document and verify the developer workflow

**Files:**
- Modify: `README.md`
- Modify: `.gitignore`
- Test: `Scripts/validate-xcode-project.sh`

**Interfaces:**
- Consumes: the completed project from Task 2.
- Produces: documented open/build/test commands and repository hygiene for Xcode user data.

- [ ] **Step 1: Add a failing documentation assertion**

Extend the validator’s `all` mode to require `README.md` to mention `open SievePilot.xcodeproj` and both package and Xcode test commands, and `.gitignore` to ignore `xcuserdata/` and `DerivedData/`.

- [ ] **Step 2: Run complete validation to verify it fails**

Run: `bash Scripts/validate-xcode-project.sh all`
Expected: FAIL because the README and ignore entries have not been updated.

- [ ] **Step 3: Update developer documentation and ignore rules**

Document:

```bash
open SievePilot.xcodeproj
swift test
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'
```

State that the Xcode command requires full Xcode. Add `xcuserdata/` and `DerivedData/` to `.gitignore`.

- [ ] **Step 4: Run all available verification**

Run:

```bash
bash Scripts/validate-xcode-project.sh all
. "$HOME/.swiftly/env.sh"
swift test
swift package dump-package >/dev/null
git diff --check
```

Expected: structural validation passes, all package tests pass, the manifest parses, and diff checking reports no errors.

- [ ] **Step 5: Run the Xcode build and app tests when available**

Run:

```bash
if xcode-select -p 2>/dev/null | grep -q 'Xcode.app'; then
  xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'
else
  echo 'SKIP: full Xcode is not installed; run this command after installation'
fi
```

Expected on this machine: explicit SKIP. With Xcode installed: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add README.md .gitignore Scripts/validate-xcode-project.sh docs/superpowers/specs/2026-11-09-macos-app-target-design.md docs/superpowers/plans/2026-11-09-macos-app-target.md
git commit -m "docs: document the Xcode app workflow"
```
