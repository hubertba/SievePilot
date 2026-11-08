# SievePilot Core Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test the platform-independent Swift core that resolves out-of-office expiry, renders safe Sieve source, scans existing scripts as raw bytes, and inserts, replaces, or removes SievePilot-owned sections without changing user-owned bytes.

**Architecture:** A Swift package named `SievePilotCore` contains immutable domain values, a generated-source renderer, a byte-oriented Sieve preamble scanner, a managed-section parser, and a patcher. The package has no SwiftUI, networking, Keychain, or third-party dependencies, allowing `swift test` to verify the destructive safety boundary before ManageSieve transport work begins.

**Tech Stack:** Swift 5.9+, Foundation, XCTest, Swift Package Manager; macOS 13 minimum.

**Spec:** `docs/superpowers/specs/2026-04-24-sievepilot-design.md`

## Global Constraints

- Target macOS 13 or newer.
- Keep the core protocol implementation free of external dependencies unless separately reviewed.
- Treat fetched scripts as raw `Data`; never decode and re-encode the complete script.
- Preserve every user-owned byte outside SievePilot-owned ranges, including BOMs, comments, invalid UTF-8, whitespace, mixed line endings, and non-ASCII literals.
- Fail closed on malformed, duplicate, nested, misplaced, or unknown-version markers.
- Place generated requirements and rules after all leading `require` commands and before the first executable command.
- The expiry condition is strict-exclusive: active only while canonical UTC `currentdate` is less than the configured instant.
- Generated user values must be escaped as Sieve strings and never interpolated as raw source.

## Review Focus

- Marker-looking text inside quoted or multiline strings must remain user content, not become a managed section; Task 4 tests this through scanner/parser integration.
- A BOM plus comments and multiple `require` commands must produce a legal insertion point without changing the prefix; Task 3 tests exact offsets and Task 5 tests exact output bytes.
- Invalid UTF-8 and mixed line endings must survive enable, update, and disable operations byte-for-byte; Task 5 tests all three operations.
- Nonexistent and repeated daylight-saving local times must never silently resolve to an unintended instant; Task 1 tests rejection and explicit offset selection.
- Unknown marker versions, duplicates, nesting, and partial markers must refuse mutation while returning the original bytes unchanged; Task 4 and Task 5 test each form.

---

## File Structure

- `Package.swift` — Swift package definition for the core library and tests.
- `Sources/SievePilotCore/Domain/AccountID.swift` — stable, ASCII-safe account identifier.
- `Sources/SievePilotCore/Domain/OutOfOfficeConfiguration.swift` — validated user configuration and resolved expiry values.
- `Sources/SievePilotCore/Domain/ManagedScriptMetadata.swift` — ownership/version metadata rendered into every owned version.
- `Sources/SievePilotCore/Time/ExpiryResolver.swift` — local-time gap/overlap resolution and UTC formatting.
- `Sources/SievePilotCore/Sieve/SieveStringEncoder.swift` — safe Sieve quoted-string encoding.
- `Sources/SievePilotCore/Sieve/ManagedSectionRenderer.swift` — metadata, requirements, and out-of-office section generation.
- `Sources/SievePilotCore/Sieve/SievePreambleScanner.swift` — byte lexer that finds the legal insertion boundary.
- `Sources/SievePilotCore/Sieve/ManagedSectionParser.swift` — byte-range detection and marker validation.
- `Sources/SievePilotCore/Sieve/SieveScriptPatcher.swift` — enable, update, and disable mutations over raw `Data`.
- `Sources/SievePilotCore/State/OutOfOfficeStateEvaluator.swift` — verified on/off/expired/malformed state derivation.
- `Tests/SievePilotCoreTests/...` — focused XCTest files matching each production unit.

### Task 1: Package, Domain Values, and Expiry Resolution

**Files:**
- Create: `Package.swift`
- Create: `Sources/SievePilotCore/Domain/AccountID.swift`
- Create: `Sources/SievePilotCore/Domain/OutOfOfficeConfiguration.swift`
- Create: `Sources/SievePilotCore/Domain/ManagedScriptMetadata.swift`
- Create: `Sources/SievePilotCore/Time/ExpiryResolver.swift`
- Create: `Tests/SievePilotCoreTests/ExpiryResolverTests.swift`
- Create: `Tests/SievePilotCoreTests/DomainValidationTests.swift`

**Interfaces:**
- Produces: `AccountID.init(rawValue: UUID)`, `AccountID.sieveToken: String`.
- Produces: `ResolvedExpiry { instant: Date, timeZoneIdentifier: String, utcOffsetSeconds: Int }`.
- Produces: `ExpiryResolver.resolve(localComponents: DateComponents, timeZone: TimeZone, repeatedTimeOffset: Int?) throws -> ResolvedExpiry`.
- Produces: `OutOfOfficeConfiguration.init(emailAddress: String, subject: String?, message: String, expiry: ResolvedExpiry) throws`.
- Produces: `ManagedScriptMetadata { accountID, versionID, predecessorSHA256 }`.

- [ ] **Step 1: Create the package manifest and failing domain/time tests**

Define tests named:

```swift
func testRejectsEmptyMessage()
func testAcceptsBlankSubjectAsNil()
func testRejectsNonexistentWarsawLocalTime()
func testRequiresOffsetForRepeatedWarsawLocalTime()
func testResolvesSelectedRepeatedTimeOffset()
func testAccountIDSieveTokenContainsOnlyASCIIIdentifierCharacters()
```

Use `Europe/Warsaw` transition dates discovered through `Calendar.nextDate` in test setup rather than hard-coding a timezone rule outside Foundation.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter 'ExpiryResolverTests|DomainValidationTests'`

Expected: build failure because the package types do not exist.

- [ ] **Step 3: Implement the domain types and expiry resolver**

Implement the interfaces above. `ExpiryResolver` must reject gaps, require `repeatedTimeOffset` when two valid instants exist, and verify that the selected offset matches one occurrence. Domain validation trims only for emptiness checks; it retains the user's original message and subject content.

- [ ] **Step 4: Run the focused and complete test suites**

Run: `swift test --filter 'ExpiryResolverTests|DomainValidationTests' && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/SievePilotCore/Domain Sources/SievePilotCore/Time Tests/SievePilotCoreTests
git commit -m "feat: add core domain and expiry resolution"
```

### Task 2: Sieve String Encoding and Managed Section Rendering

**Files:**
- Create: `Sources/SievePilotCore/Sieve/SieveStringEncoder.swift`
- Create: `Sources/SievePilotCore/Sieve/ManagedSectionRenderer.swift`
- Create: `Tests/SievePilotCoreTests/SieveStringEncoderTests.swift`
- Create: `Tests/SievePilotCoreTests/ManagedSectionRendererTests.swift`

**Interfaces:**
- Consumes: `AccountID`, `OutOfOfficeConfiguration`, `ManagedScriptMetadata` from Task 1.
- Produces: `SieveStringEncoder.encodeQuoted(_ value: String) throws -> Data`.
- Produces: `ManagedSectionRenderer.renderMetadata(_ metadata: ManagedScriptMetadata, lineEnding: LineEnding) -> Data`.
- Produces: `ManagedSectionRenderer.renderOutOfOffice(configuration: OutOfOfficeConfiguration, accountID: AccountID, lineEnding: LineEnding) throws -> RenderedManagedSections`.
- Produces: `LineEnding { case lf, crlf }` and `RenderedManagedSections { metadata, requirements, rule }`.

- [ ] **Step 1: Write failing encoding and rendering tests**

Test exact output for:

```swift
func testEscapesQuoteAndBackslash()
func testRejectsNULAndNewlineInQuotedString()
func testRendersCanonicalUTCStrictExclusiveCondition()
func testOmitsSubjectTagWhenSubjectIsBlank()
func testRendersAddressesAndStableHandle()
func testUsesRequestedCRLFLineEndings()
```

Assert the expiry line contains:

```text
if currentdate :zone "+0000" :value "lt" "iso8601" "2026-04-24T15:00:00Z"
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter 'SieveStringEncoderTests|ManagedSectionRendererTests'`

Expected: build failure because renderer types do not exist.

- [ ] **Step 3: Implement encoding and rendering**

Use UTF-8 generated bytes only. Reject values that cannot be represented safely as a Sieve quoted string; do not add multiline-literal generation in v1. Generate versioned ASCII markers exactly as specified by the design and a stable handle derived from `AccountID.sieveToken`.

- [ ] **Step 4: Run focused and complete tests**

Run: `swift test --filter 'SieveStringEncoderTests|ManagedSectionRendererTests' && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/Sieve/SieveStringEncoder.swift Sources/SievePilotCore/Sieve/ManagedSectionRenderer.swift Tests/SievePilotCoreTests
git commit -m "feat: render safe managed Sieve sections"
```

### Task 3: Byte-Oriented Sieve Preamble Scanner

**Files:**
- Create: `Sources/SievePilotCore/Sieve/SievePreambleScanner.swift`
- Create: `Tests/SievePilotCoreTests/SievePreambleScannerTests.swift`

**Interfaces:**
- Produces: `SievePreambleScanner.scan(_ script: Data) throws -> SievePreamble`.
- Produces: `SievePreamble { insertionOffset: Int, preferredLineEnding: LineEnding, hasUTF8BOM: Bool }`.
- Produces: `SievePreambleError { malformedString, malformedMultilineLiteral, malformedRequire, unsupportedLeadingSyntax }`.

- [ ] **Step 1: Write failing scanner tests**

Create table-driven tests for:

```swift
func testEmptyScriptInsertsAtZero()
func testInsertionFollowsBOMCommentsAndMultipleRequires()
func testCommentsBetweenRequiresDoNotEndPreamble()
func testRequireTextInsideQuotedStringIsIgnored()
func testRequireTextInsideMultilineLiteralIsIgnored()
func testDetectsCRLFPreference()
func testMalformedLeadingStringFailsClosed()
func testInvalidUTF8OutsideRecognizedASCIITokensDoesNotFail()
```

Each successful test asserts the exact integer byte offset into the original `Data`.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter SievePreambleScannerTests`

Expected: build failure because scanner types do not exist.

- [ ] **Step 3: Implement the minimal byte lexer**

Recognize ASCII whitespace, `#` line comments, `/* ... */` comments, quoted strings with escapes, Sieve multiline literals, identifiers, brackets, commas, semicolons, and leading `require` commands. Stop at the first non-`require` command. Never decode arbitrary user bytes as Unicode.

- [ ] **Step 4: Run focused and complete tests**

Run: `swift test --filter SievePreambleScannerTests && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/Sieve/SievePreambleScanner.swift Tests/SievePilotCoreTests/SievePreambleScannerTests.swift
git commit -m "feat: scan Sieve preambles as raw bytes"
```

### Task 4: Managed Section Parsing and Conflict Detection

**Files:**
- Create: `Sources/SievePilotCore/Sieve/ManagedSectionParser.swift`
- Create: `Tests/SievePilotCoreTests/ManagedSectionParserTests.swift`

**Interfaces:**
- Consumes: `SievePreambleScanner` from Task 3.
- Produces: `ManagedSectionParser.parse(_ script: Data, preamble: SievePreamble) throws -> ManagedSections`.
- Produces: `ManagedSections { metadata: Range<Int>?, requirements: Range<Int>?, outOfOfficeRule: Range<Int>? }`.
- Produces: `ManagedSectionError { partialMarker, duplicateSection, nestedSection, unknownVersion, misplacedSection, markerInsideGeneratedSection }`.

- [ ] **Step 1: Write failing parser tests**

Test:

```swift
func testFindsOneValidSectionSetAtInsertionBoundary()
func testMarkerTextInsideQuotedStringIsIgnored()
func testMarkerTextInsideMultilineLiteralIsIgnored()
func testRejectsPartialMarkerPair()
func testRejectsDuplicateSection()
func testRejectsNestedSection()
func testRejectsUnknownVersion()
func testRejectsSectionAfterUserExecutableCommand()
func testAllowsMetadataOnlyDisabledVersion()
```

Assert exact byte ranges for valid sections.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter ManagedSectionParserTests`

Expected: build failure because parser types do not exist.

- [ ] **Step 3: Implement marker parsing over lexical regions**

Reuse lexical skipping rules so marker-looking bytes inside strings, multiline literals, or block comments are ignored. Markers are recognized only as complete ASCII line comments. Require metadata to be present for owned versions and require all owned sections to be contiguous at the scanner's insertion boundary.

- [ ] **Step 4: Run focused and complete tests**

Run: `swift test --filter ManagedSectionParserTests && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/Sieve/ManagedSectionParser.swift Tests/SievePilotCoreTests/ManagedSectionParserTests.swift
git commit -m "feat: detect managed Sieve section conflicts"
```

### Task 5: Raw-Byte Script Patching

**Files:**
- Create: `Sources/SievePilotCore/Sieve/SieveScriptPatcher.swift`
- Create: `Tests/SievePilotCoreTests/SieveScriptPatcherTests.swift`
- Create: `Tests/SievePilotCoreTests/Fixtures/mixed-line-endings.sieve`
- Create: `Tests/SievePilotCoreTests/Fixtures/invalid-utf8.sieve`

**Interfaces:**
- Consumes: renderer from Task 2, scanner from Task 3, parser from Task 4.
- Produces: `SieveScriptMutation { case enable(OutOfOfficeConfiguration), disable }`.
- Produces: `SieveScriptPatcher.apply(_ mutation: SieveScriptMutation, to script: Data, metadata: ManagedScriptMetadata, accountID: AccountID) throws -> Data`.

- [ ] **Step 1: Write failing end-to-end patch tests**

Test:

```swift
func testEnableInsertsAfterExistingRequiresBeforeExecutableCode()
func testUpdateReplacesOnlyOwnedRanges()
func testDisableLeavesMetadataAndRemovesRequirementsAndRule()
func testEnablePreservesBOMInvalidUTF8AndMixedLineEndingsOutsideOwnedRanges()
func testDisableRestoresAllOriginalUserBytesInOrder()
func testMalformedMarkersReturnErrorWithoutOutputMutation()
func testUnknownVersionReturnsErrorWithoutOutputMutation()
func testRepeatedEnableIsDeterministicApartFromMetadataVersionValues()
```

For preservation tests, split expected output around generated ranges and assert exact `Data` equality for every user-owned slice.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter SieveScriptPatcherTests`

Expected: build failure because patcher types do not exist.

- [ ] **Step 3: Implement patching with descending byte-range replacements**

Parse before mutation, build generated sections separately, and apply removals/replacements from highest offset to lowest so earlier offsets remain valid. On any scan, parse, render, or validation error, throw without returning partially modified data.

- [ ] **Step 4: Run focused and complete tests**

Run: `swift test --filter SieveScriptPatcherTests && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/Sieve/SieveScriptPatcher.swift Tests/SievePilotCoreTests
git commit -m "feat: patch Sieve scripts without changing user bytes"
```

### Task 6: Verified Out-of-Office State Evaluation

**Files:**
- Create: `Sources/SievePilotCore/State/OutOfOfficeStateEvaluator.swift`
- Create: `Tests/SievePilotCoreTests/OutOfOfficeStateEvaluatorTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: managed-section parser and expiry representation from earlier tasks.
- Produces: `VerifiedOutOfOfficeState { case off, on(configuration: ParsedOutOfOfficeConfiguration), expiryPassedServerClockApplies(configuration: ParsedOutOfOfficeConfiguration), malformed(reason: String) }`.
- Produces: `OutOfOfficeStateEvaluator.evaluate(activeScript: Data?, now: Date) -> VerifiedOutOfOfficeState`.
- `activeScript == nil` means a verified no-active-script state and returns `.off`.

- [ ] **Step 1: Write failing state tests**

Test:

```swift
func testNoActiveScriptIsVerifiedOff()
func testMetadataOnlyScriptIsVerifiedOff()
func testFutureRuleIsVerifiedOn()
func testLocallyExpiredRuleUsesServerClockWarningState()
func testMalformedOwnedRuleIsMalformedNotOff()
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter OutOfOfficeStateEvaluatorTests`

Expected: build failure because evaluator types do not exist.

- [ ] **Step 3: Implement state parsing and evaluation**

Parse only the strict generated v1 form. Do not infer arbitrary user-authored vacation rules as SievePilot state. Update `README.md` status to say the core engine is under implementation and document `swift test`.

- [ ] **Step 4: Run all tests and package validation**

Run: `swift test && swift package dump-package >/dev/null && git diff --check`

Expected: all tests pass; package manifest parses; no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/State Tests/SievePilotCoreTests/OutOfOfficeStateEvaluatorTests.swift README.md
git commit -m "feat: evaluate verified out-of-office state"
```

## Self-Review Result

- Spec coverage in this phase: raw-byte preservation, grammar-safe insertion, generated expiry semantics, escaping, DST resolution, managed metadata, marker conflict handling, and verified local script-state derivation.
- Deferred to the next plans: ManageSieve framing and STARTTLS, SASL, SRV discovery, certificate identity, version upload/concurrency/restore, Keychain persistence, SwiftUI menu-bar UI, diagnostics, integration servers, signing, and release automation.
- Interface names and types are consistent across all six tasks.
- Each task has a focused red-green test cycle and an independent commit.
