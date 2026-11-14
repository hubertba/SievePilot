# Sieve Script Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a confirmed Delete Script action that can deactivate and permanently delete the selected active or inactive server-side Sieve script.

**Architecture:** `SieveAccountService` owns the one-session re-list/deactivate/delete/verify workflow and returns either a verified snapshot or an explicitly unknown outcome. `AppModel` serializes the mutation with existing critical operations and maps outcomes to safe UI state. `OutOfOfficeView` captures the selected script in a confirmation alert and invokes the model only after the destructive warning is accepted.

**Tech Stack:** Swift 6, Swift concurrency/actors, SwiftUI, XCTest, ManageSieve RFC 5804 commands.

**Spec:** `docs/superpowers/specs/2026-11-14-script-deletion-design.md`

## Global Constraints

- Build on the repository's current uncommitted script-inspection and ManageSieve changes; do not discard or overwrite unrelated working-tree changes.
- Active deletion must send `SETACTIVE ""` before `DELETESCRIPT`.
- Never claim success without a post-mutation `LISTSCRIPTS` verification and active-script readback when an active script remains.
- Ambiguous failures after a mutation command produce an unknown outcome and require Refresh.
- No backup, undo, replacement activation, automatic rollback, dependency addition, or unrelated refactor.
- The confirmation must name the script and explicitly warn when deletion leaves no active Sieve script or mail rules.

## Review Focus

- The script disappears between UI confirmation and execution: core test treats the already-absent target as verified deletion without issuing mutation commands.
- The script's active flag changes after the displayed snapshot: core test proves the fresh server list, not stale UI state, decides whether to deactivate.
- The connection drops during deactivation, deletion, or post-delete verification: core tests require `.unknown`, never verified success.
- The server definitely rejects deletion after successful deactivation: core and model tests require a specific “stored but inactive / no active script” explanation.
- A different script remains active after deletion: core test requires its bytes and out-of-office state in the returned verified snapshot.

---

### Task 1: Core one-session deletion workflow

**Files:**
- Modify: `Sources/SievePilotCore/Service/SieveAccountService.swift`
- Modify: `Tests/SievePilotCoreTests/Service/SieveAccountServiceTests.swift`

**Interfaces:**
- Consumes: `AuthenticatedManageSieveSession.listScripts`, `setActive(name:timeout:)`, `deleteScript(name:timeout:)`, and `getScript(name:timeout:)`.
- Produces: `public enum ScriptDeletionOutcome: Equatable, Sendable { case verified(VerifiedAccountSnapshot); case unknown }`.
- Produces: `public func deleteScript(account: AccountConfiguration, name: String) async throws -> ScriptDeletionOutcome`.
- Produces: `SieveAccountServiceError.scriptDeactivationRejected` and `SieveAccountServiceError.scriptDeletionRejected(deactivated: Bool)`.

- [ ] **Step 1: Extend the service-session fake for deletion failures and list failures**

Add `deleteError`, an optional list failure count/error, and make `deleteScript` throw before removing the script when configured. Keep event recording deterministic.

- [ ] **Step 2: Write failing tests for inactive, active, and already-absent deletion**

Add tests named:

- `testDeleteInactiveScriptDeletesAndReturnsVerifiedSnapshot`
- `testDeleteActiveScriptDeactivatesThenDeletesAndReturnsVerifiedOffSnapshot`
- `testDeleteUsesFreshActiveStateRatherThanCallerSnapshot`
- `testDeleteAlreadyAbsentScriptReturnsVerifiedSnapshotWithoutMutation`
- `testDeletePreservesAndReadsBackDifferentRemainingActiveScript`

Assert exact event order. Active deletion must include `active:` before `delete:<name>`; inactive and absent deletion must not send `SETACTIVE`; a remaining active script must be fetched and represented in `VerifiedAccountSnapshot`.

- [ ] **Step 3: Run the focused core tests and verify they fail**

Run: `swift test --filter SieveAccountServiceTests`

Expected: FAIL because `ScriptDeletionOutcome` and `SieveAccountService.deleteScript(account:name:)` do not exist.

- [ ] **Step 4: Implement verified snapshot construction shared by refresh and deletion**

Add a private helper with this signature:

```swift
private static func verifiedSnapshot(
    session: any AuthenticatedManageSieveSession,
    capabilities: ManageSieveCapabilities,
    accountID: AccountID,
    now: Date
) async throws -> VerifiedAccountSnapshot
```

It lists scripts, finds the active name, fetches its bytes when present, evaluates out-of-office state, and returns the complete snapshot. Refactor `refresh(account:)` to use it without changing refresh behavior.

- [ ] **Step 5: Implement the minimal deletion workflow**

Implement `deleteScript(account:name:)` in one authenticated session: require the current accepted capabilities, list current entries, return a verified snapshot if the target is already absent, deactivate with `setActive(name: "")` when the fresh entry is active, delete the target, then call the verified snapshot helper.

Map a definite `NO` from deactivation to `.scriptDeactivationRejected`; map a definite `NO` from deletion to `.scriptDeletionRejected(deactivated: wasDeactivated)`. Return `.unknown` for cancellation/ambiguous errors from either mutation command or post-mutation verification; allow pre-mutation read failures to throw normally.

- [ ] **Step 6: Run the focused tests and verify the success-path tests pass**

Run: `swift test --filter SieveAccountServiceTests`

Expected: the new success-path tests PASS.

- [ ] **Step 7: Write failing tests for rejection and ambiguity**

Add tests named:

- `testDeleteReturnsUnknownWhenDeactivationOutcomeIsAmbiguous`
- `testDeleteReturnsUnknownWhenDeletionOutcomeIsAmbiguousAfterDeactivation`
- `testDeleteReturnsUnknownWhenPostDeleteVerificationFails`
- `testDeleteThrowsSpecificErrorWhenDeactivationIsRejected`
- `testDeleteThrowsSpecificErrorWhenDeletionIsRejectedAfterDeactivation`

Use `ManageSieveClientError.transport` for ambiguous mutation errors and `ManageSieveClientError.serverNo` for definite rejections. Assert `.scriptDeletionRejected(deactivated: true)` and that the fake's active script is `nil` after successful deactivation followed by definite delete rejection.

- [ ] **Step 8: Run focused core tests and make all deletion tests pass**

Run: `swift test --filter SieveAccountServiceTests`

Expected: PASS.

- [ ] **Step 9: Commit the core deletion workflow**

```bash
git add Sources/SievePilotCore/Service/SieveAccountService.swift Tests/SievePilotCoreTests/Service/SieveAccountServiceTests.swift
git commit -m "feat: add verified sieve script deletion"
```

---

### Task 2: App-model deletion state and user-safe errors

**Files:**
- Modify: `SievePilotApp/AppDependencies.swift`
- Modify: `SievePilotApp/AppModel.swift`
- Modify: `SievePilotAppTests/AppModelTests.swift`
- Modify: `SievePilotAppTests/OutOfOfficeFlowTests.swift`

**Interfaces:**
- Consumes: `ScriptDeletionOutcome` and `SieveAccountService.deleteScript(account:name:)` from Task 1.
- Produces on `SieveAccountServicing`: `func deleteScript(account: AccountConfiguration, name: String) async throws -> ScriptDeletionOutcome`.
- Produces on `AppModel`: `var canDeleteSelectedScript: Bool` and `func deleteScript(named name: String) async`.

- [ ] **Step 1: Extend app test fakes with queued deletion outcomes**

Add deletion calls, queued `Result<ScriptDeletionOutcome, Error>` values, and an optional deletion gate to `AppService`. Update every `SieveAccountServicing` conformance to implement the new method.

- [ ] **Step 2: Write failing model tests for verified and unknown outcomes**

Add tests named:

- `testDeleteSelectedScriptAdoptsVerifiedSnapshotAndMovesOffDeletedSelection`
- `testDeleteSelectedActiveScriptCanLeaveNoActiveScript`
- `testDeleteScriptUnknownOutcomeRequiresRefresh`
- `testDeleteScriptUsesConfirmedNameEvenIfSelectionChanges`

Assert the exact requested name, verified list/status updates, deleted bytes are no longer displayed, and unknown text equals: `SievePilot could not verify whether the script was deleted. Refresh to check the server before trying again.`

- [ ] **Step 3: Run focused app tests and verify they fail**

Run:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS' \
  -only-testing:SievePilotAppTests/OutOfOfficeFlowTests
```

Expected: FAIL because the servicing method and model deletion API do not exist.

- [ ] **Step 4: Implement model operation serialization and successful outcome handling**

Add a distinct internal `Operation.deleteScript` using the existing applying/in-progress presentation state and critical-operation behavior. `canDeleteSelectedScript` is true only when an account and selected listed script exist and no operation is active.

`deleteScript(named:)` must reject names not present in the current displayed list, call the service through `run`, adopt `.verified` snapshots, clear the deleted script's loaded bytes/inspection state before adoption, and use `.stale` rather than `.verified` if lifecycle invalidation occurred during the critical mutation.

- [ ] **Step 5: Implement safe error mapping**

Handle `.unknown` with the exact Refresh message from Step 2. Handle `scriptDeactivationRejected` with `The server refused to deactivate the active script, so it was not deleted. Refresh to verify the server state.` Handle `scriptDeletionRejected(deactivated: true)` with `The script was deactivated but the server refused to delete it. It remains stored and inactive, and no Sieve script is active. Refresh to verify the server state.` Handle `deactivated: false` with `The server refused to delete the script. Refresh to verify the server state.` Do not include server-provided text.

- [ ] **Step 6: Add model tests for concurrency, lifecycle invalidation, and rejection messages**

Add tests named:

- `testDeleteScriptDisablesAnotherDeleteWhileInFlight`
- `testLifecycleInvalidationDuringVerifiedDeleteLeavesStateStale`
- `testDeleteRejectionAfterDeactivationExplainsInactiveState`
- `testDeactivationRejectionSaysScriptWasNotDeleted`

Use the deletion gate to prove only one service call occurs and the model reports an operation in progress.

- [ ] **Step 7: Run focused app tests and make them pass**

Run:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS' \
  -only-testing:SievePilotAppTests/OutOfOfficeFlowTests
```

Expected: PASS.

- [ ] **Step 8: Run the broader app-model tests**

Run:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS' \
  -only-testing:SievePilotAppTests/AppModelTests \
  -only-testing:SievePilotAppTests/OutOfOfficeFlowTests
```

Expected: PASS.

- [ ] **Step 9: Commit the app-model integration**

```bash
git add SievePilotApp/AppDependencies.swift SievePilotApp/AppModel.swift \
  SievePilotAppTests/AppModelTests.swift SievePilotAppTests/OutOfOfficeFlowTests.swift
git commit -m "feat: expose sieve script deletion in app model"
```

---

### Task 3: Destructive confirmation UI and user documentation

**Files:**
- Modify: `SievePilotApp/Views/OutOfOfficeView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `AppModel.canDeleteSelectedScript` and `AppModel.deleteScript(named:)` from Task 2.
- Produces: a selected-script **Delete Script** button and script-specific confirmation alert.

- [ ] **Step 1: Add a confirmation value that captures the clicked script**

In `OutOfOfficeView`, add a private `Identifiable` value containing `name: String` and `wasActive: Bool`, plus `@State` for the pending confirmation. Capturing the name prevents a later selection change from deleting a different script.

- [ ] **Step 2: Add the destructive button to selected-script details**

Place **Delete Script** after the selected script content. Set the pending confirmation from `model.selectedScriptEntry`; disable it when `model.canDeleteSelectedScript` is false.

- [ ] **Step 3: Add the named destructive alert**

Use an item-based alert titled `Delete “<name>”?`. For an inactive script, explain that deletion is permanent. For an active script, use: `This script is active. SievePilot will deactivate it first, leaving no active Sieve script or mail rules, and then permanently delete it.` The destructive action is **Deactivate and Delete** for active scripts and **Delete Script** otherwise; it calls `await model.deleteScript(named: capturedName)`.

- [ ] **Step 4: Update README usage and safety notes**

Document selecting and deleting a server script, the active-script deactivation behavior, permanence, and the possibility that an interrupted operation requires Refresh to determine the result. Update the existing statement that SievePilot does not offer script pruning/restore without implying automatic pruning or undo.

- [ ] **Step 5: Build and run the app tests**

Run:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Run package tests and project validation**

Run:

```bash
swift test
./Scripts/validate-xcode-project.sh
./Scripts/test-xcode-project-validator.sh
```

Expected: all commands exit 0.

- [ ] **Step 7: Commit UI and documentation**

```bash
git add SievePilotApp/Views/OutOfOfficeView.swift README.md
git commit -m "feat: add delete script confirmation"
```

---

### Task 4: Final regression verification

**Files:**
- Verify only; modify files only if a failing test identifies a feature regression.

**Interfaces:**
- Consumes: all interfaces from Tasks 1–3.
- Produces: evidence that core, app, UI compilation, and project structure remain healthy.

- [ ] **Step 1: Inspect the final diff without disturbing pre-existing work**

Run: `git status --short && git diff --check && git log --oneline -4`

Expected: no whitespace errors; pre-existing unrelated modifications remain present and uncommitted unless they were necessarily edited by this feature.

- [ ] **Step 2: Run the full verification suite**

Run:

```bash
swift test && \
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS' && \
./Scripts/validate-xcode-project.sh && \
./Scripts/test-xcode-project-validator.sh
```

Expected: all commands exit 0 and Xcode reports `** TEST SUCCEEDED **`.

- [ ] **Step 3: Manually verify the confirmation copy in both states**

Launch the app against test data or previews, select one inactive and one active script, and confirm the alert names the captured script and uses the correct inactive versus active warning. Do not complete deletion against a non-test mail account.

- [ ] **Step 4: Commit any verification-only fixes separately**

If needed:

```bash
git add <only-files-fixed-during-verification>
git commit -m "fix: address script deletion regression"
```
