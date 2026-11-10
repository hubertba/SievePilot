# SievePilot Initial Release Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing core and fake-transport engine into a usable one-account macOS menu-bar app with live STARTTLS ManageSieve connectivity, Keychain credentials, safe script updates, and verified out-of-office controls.

**Architecture:** Add a SwiftNIO/NIOSSL live transport behind the existing `ManageSieveTransport` boundary, then compose discovery, persistence, Keychain, authenticated sessions, and a concurrency-checked script repository behind an observable app model. Views remain declarative and update only from verified server snapshots.

**Tech Stack:** Swift 5.9, macOS 13+, SwiftUI/AppKit, SwiftNIO, NIOSSL, Swift Certificates, Security.framework, DNSService APIs, Swift Testing, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-10-initial-release-completion-design.md`

## Global Constraints

- Never read, print, copy, log, or commit credentials from the user’s home-directory `.env`.
- Never authenticate before successful TLS trust and service-identity validation.
- Never trust pre-TLS capabilities or provide a trust-bypass control.
- Preserve all user-owned Sieve bytes and never overwrite a user-named script object in place.
- Keep credentials, SASL payloads, raw scripts, and unbounded server text out of errors and logs.
- Target macOS 13 or newer.
- Initial UI supports one account, while storage and service interfaces retain stable `AccountID` ownership.
- Production operations use one fresh authenticated connection and close it after the operation.
- Live interoperability with real credentials is opt-in and requires separate explicit authorization.

## Review Focus

- A TLS-valid certificate for the discovered target but not the source-domain DNS-ID/SRV-ID must fail closed — Task 2 tests this.
- Cancellation while NIO connect/read/write/TLS upgrade is suspended must release the waiter and close once — Task 1 and Task 2 test this.
- Server state changing between baseline refresh and activation must stop without activating stale content — Task 5 tests this.
- A Keychain or settings save partially failing must not leave a usable account pointing at a missing/wrong password — Task 4 tests transactional save behavior.
- UI state after timeout, ambiguous activation, wake, or reconnect must be unknown/stale until verified — Tasks 6 and 7 test this.

---

### Task 1: SwiftNIO transport foundation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SievePilotCore/Live/NIOManageSieveTransport.swift`
- Create: `Sources/SievePilotCore/Live/NIOTransportErrors.swift`
- Create: `Tests/SievePilotCoreTests/Live/NIOManageSieveTransportTests.swift`

**Interfaces:**
- Consumes: existing `ManageSieveTransport` and `ManageSieveTLSIdentityRequest`.
- Produces:

```swift
public final class NIOManageSieveTransport: ManageSieveTransport, @unchecked Sendable {
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: Int
    }

    public init(endpoint: Endpoint, eventLoopGroup: EventLoopGroup? = nil)
}
```

- [ ] **Step 1: Add package dependencies and write failing plain-TCP transport tests**

Add `swift-nio`, `swift-nio-ssl`, and `swift-certificates`; link `NIOCore`, `NIOPosix`, `NIOSSL`, and `X509` to `SievePilotCore`. Tests use a loopback `ServerBootstrap` and assert connect, fragmented reads, bounded read splitting, ordered writes, EOF, connect failure, pending-read release, idempotent close, and no byte-bearing error descriptions.

- [ ] **Step 2: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter NIOManageSieveTransportTests`
Expected: FAIL because the transport does not exist.

- [ ] **Step 3: Implement the actor-protected channel bridge**

Use one channel inbound handler that forwards `ByteBuffer` chunks into a lock/actor-isolated queue. `read(maxBytes:)` returns at most the requested count and retains a suffix. `write(_:)` completes after `writeAndFlush`. `close()` resumes every pending continuation exactly once and shuts down only an internally owned event-loop group.

`upgradeToTLS(identity:)` remains an explicit unsupported-state failure until Task 2; no plaintext authentication path is introduced.

- [ ] **Step 4: Run GREEN and full package tests**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter NIOManageSieveTransportTests
swift test
```

Expected: transport suite and existing 141 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/SievePilotCore/Live Tests/SievePilotCoreTests/Live
git commit -m "feat: add live ManageSieve TCP transport"
```

### Task 2: STARTTLS and service-identity validation

**Files:**
- Create: `Sources/SievePilotCore/Live/ManageSieveTLSIdentityValidator.swift`
- Modify: `Sources/SievePilotCore/Live/NIOManageSieveTransport.swift`
- Create: `Tests/SievePilotCoreTests/Live/ManageSieveTLSIdentityValidatorTests.swift`
- Modify: `Tests/SievePilotCoreTests/Live/NIOManageSieveTransportTests.swift`
- Add fixtures: `Tests/SievePilotCoreTests/Fixtures/TLS/*`

**Interfaces:**
- Consumes: `ManageSieveTLSIdentityRequest.referenceIdentifiers`.
- Produces:

```swift
public enum ManageSieveReferenceIdentifier: Equatable, Sendable {
    case dns(String)
    case srv(service: String, domain: String)
}

public struct ManageSieveTLSIdentityValidator: Sendable {
    public func validate(
        certificateChain: [Certificate],
        identifiers: [ManageSieveReferenceIdentifier],
        trustRoots: CertificateStore
    ) throws
}
```

Update `ManageSieveTLSIdentityRequest` to carry typed identifiers while retaining a deprecated compatibility initializer only if existing tests require it.

- [ ] **Step 1: Write failing pure identity tests**

Cover exact DNS SAN, ASCII case folding, valid leftmost wildcard, forbidden partial/multi-label wildcard, SAN-only behavior, malformed names, no Common Name fallback, source-domain DNS-ID success, SRV-ID success, discovered-target-only rejection, expired/untrusted chain rejection, and empty identifiers.

- [ ] **Step 2: Run identity RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveTLSIdentityValidatorTests`
Expected: FAIL on missing validator/types.

- [ ] **Step 3: Implement chain and SAN validation**

Use Swift Certificates for chain verification against system roots supplied by the production factory and for SAN parsing. Match DNS-ID and SRV-ID explicitly; the connection target is never added to identifiers implicitly.

- [ ] **Step 4: Write failing STARTTLS pipeline tests**

Use a loopback NIO server with a plaintext greeting/STARTTLS response followed by TLS. Assert insertion on the existing channel, successful encrypted reads/writes, handshake failure, identity mismatch, cancellation, close during handshake, and no post-failure writes.

- [ ] **Step 5: Implement `upgradeToTLS(identity:)`**

Insert `NIOSSLClientHandler` after plaintext bytes are drained. Complete only after handshake and custom verification succeed. Any failure closes the channel and releases pending operations.

- [ ] **Step 6: Run GREEN/full tests and commit**

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter 'ManageSieveTLSIdentityValidatorTests|NIOManageSieveTransportTests'
swift test
git diff --check
git add Sources/SievePilotCore/Live Sources/SievePilotCore/ManageSieve/ManageSieveTransport.swift Tests/SievePilotCoreTests/Live Tests/SievePilotCoreTests/Fixtures/TLS
git commit -m "feat: secure live ManageSieve STARTTLS"
```

### Task 3: SRV discovery and endpoint selection

**Files:**
- Create: `Sources/SievePilotCore/Account/SieveServiceDiscovery.swift`
- Create: `Sources/SievePilotCore/Account/DNSServiceResolver.swift`
- Create: `Tests/SievePilotCoreTests/Account/SieveServiceDiscoveryTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SieveServiceEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let referenceIdentifiers: [ManageSieveReferenceIdentifier]
}

public protocol SieveSRVResolving: Sendable {
    func records(for name: String) async throws -> [SieveSRVRecord]
}

public struct SieveServiceDiscovery: Sendable {
    public func discover(emailAddress: String) async throws -> SieveServiceEndpoint
}
```

- [ ] **Step 1: Write failing discovery tests**

Cover email/domain validation, exact `_sieve._tcp.<domain>` query, priority ordering, deterministic weighted selection through injected randomness, trailing-dot normalization, invalid target/port, explicit no-service target `.`, timeout/cancellation, no records, and identifiers containing SRV-ID plus source-domain DNS-ID but not target DNS-ID.

- [ ] **Step 2: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter SieveServiceDiscoveryTests`

- [ ] **Step 3: Implement injected selection and production DNSService resolver**

Wrap DNSService callbacks in cancellation-safe continuations. Bound record count and total response bytes. Discovery returns one endpoint; manual configuration is represented separately by Task 4.

- [ ] **Step 4: Run GREEN/full tests and commit**

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter SieveServiceDiscoveryTests
swift test
git add Sources/SievePilotCore/Account Tests/SievePilotCoreTests/Account
git commit -m "feat: discover ManageSieve services"
```

### Task 4: Account settings and Keychain credentials

**Files:**
- Create: `Sources/SievePilotCore/Account/AccountConfiguration.swift`
- Create: `Sources/SievePilotCore/Account/AccountConfigurationStore.swift`
- Create: `Sources/SievePilotCore/Account/KeychainCredentialStore.swift`
- Create: `Tests/SievePilotCoreTests/Account/AccountConfigurationStoreTests.swift`
- Create: `Tests/SievePilotCoreTests/Account/KeychainCredentialStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public enum AccountEndpointPolicy: Equatable, Codable, Sendable {
    case automatic(sourceDomain: String)
    case manual(host: String, port: Int)
}

public struct AccountConfiguration: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let accountID: AccountID
    public var emailAddress: String
    public var username: String
    public var endpointPolicy: AccountEndpointPolicy
}

public protocol AccountConfigurationStoring: Sendable { /* load/save/delete */ }
public protocol CredentialStoring: Sendable { /* read/write/delete password Data */ }
```

- [ ] **Step 1: Write failing validation/persistence tests**

Cover schema v1 round-trip, atomic replacement, corrupt/unknown-version fail-closed behavior, no secret fields in JSON, email/username/manual endpoint validation, and stable account IDs.

- [ ] **Step 2: Write failing Keychain-boundary tests**

Inject a `SecurityClient` wrapper and assert generic-password query attributes, update-vs-add behavior, duplicate handling, not-found behavior, deletion, redacted errors, and temporary password-buffer wiping. Add an opt-in integration test guarded by `SIEVEPILOT_KEYCHAIN_INTEGRATION=1` using a random service and guaranteed cleanup; it must use synthetic data only.

- [ ] **Step 3: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter 'AccountConfigurationStoreTests|KeychainCredentialStoreTests'`

- [ ] **Step 4: Implement settings and Keychain stores**

Store settings under Application Support with data protection/owner-only file permissions where available. Provide one coordinator operation that saves credentials first, atomically saves settings second, and removes the newly written credential if settings save fails.

- [ ] **Step 5: Run GREEN/full tests and commit**

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter 'AccountConfigurationStoreTests|KeychainCredentialStoreTests'
swift test
git add Sources/SievePilotCore/Account Tests/SievePilotCoreTests/Account
git commit -m "feat: persist SievePilot account credentials"
```

### Task 5: Session factory and safe script repository

**Files:**
- Create: `Sources/SievePilotCore/Service/ManageSieveSessionFactory.swift`
- Create: `Sources/SievePilotCore/Service/SieveAccountService.swift`
- Create: `Sources/SievePilotCore/Service/OwnedScriptManifest.swift`
- Create: `Sources/SievePilotCore/Service/OwnedScriptManifestStore.swift`
- Create: `Tests/SievePilotCoreTests/Service/ManageSieveSessionFactoryTests.swift`
- Create: `Tests/SievePilotCoreTests/Service/SieveAccountServiceTests.swift`

**Interfaces:**
- Produces:

```swift
public struct VerifiedAccountSnapshot: Equatable, Sendable {
    public let activeScriptName: String?
    public let activeScript: Data?
    public let outOfOfficeState: OutOfOfficeState
    public let verifiedAt: Date
    public let capabilities: ManageSieveCapabilities
}

public enum AccountMutationOutcome: Equatable, Sendable {
    case verified(VerifiedAccountSnapshot)
    case conflict
    case unknown
}

public actor SieveAccountService {
    public func refresh(account: AccountConfiguration) async throws -> VerifiedAccountSnapshot
    public func applyOutOfOffice(account: AccountConfiguration, configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome
}
```

- [ ] **Step 1: Write failing session-factory tests**

Cover automatic/manual endpoint selection, manual DNS-ID, missing credential, connection/TLS/auth failure classification, PLAIN preference, LOGIN fallback, capability requirements, fresh connection per operation, and guaranteed logout/close.

- [ ] **Step 2: Implement authenticated session factory**

Compose stores/discovery/transport/client without exposing password outside operation scope.

- [ ] **Step 3: Write failing repository refresh tests**

Cover no active script, active binary script, verified on/off/expired, malformed managed markers, ownership mismatch, unsupported capability state, and timestamping only after complete verification.

- [ ] **Step 4: Write failing mutation transcript tests**

Cover baseline digest, candidate patching, `CHECKSCRIPT`, random owned name collision retry, `PUTSCRIPT`, repeated baseline check, conflict before activation, `SETACTIVE`, read-back verification, interruption returning unknown, quota/NO, no overwrite of user names, manifest persistence, rollback eligibility, and conservative retention after manifest loss.

- [ ] **Step 5: Implement repository and manifest**

Use injected session/client factories, clock, random bytes, and stores. SHA-256 uses CryptoKit. Every mutation starts with refresh and returns success only after byte-identical active read-back.

- [ ] **Step 6: Run GREEN/full tests and commit**

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter 'ManageSieveSessionFactoryTests|SieveAccountServiceTests'
swift test
git diff --check
git add Sources/SievePilotCore/Service Tests/SievePilotCoreTests/Service
git commit -m "feat: safely manage server Sieve versions"
```

### Task 6: Observable application model and setup flow

**Files:**
- Rewrite: `SievePilotApp/AppModel.swift`
- Create: `SievePilotApp/AppDependencies.swift`
- Create: `SievePilotApp/Views/SetupView.swift`
- Create: `SievePilotApp/Views/StatusBanner.swift`
- Modify: `SievePilotApp/SievePilotApp.swift`
- Rewrite: `SievePilotAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: account coordinator, discovery, session factory, and account service protocols.
- Produces an `@MainActor @Observable final class AppModel` with setup form fields, persisted-account state, operation state, verified snapshot, persistent user-facing error, `load()`, `testAndSave()`, `refresh()`, and `deleteAccount()`.

- [ ] **Step 1: Write failing app-model tests**

Cover first run, automatic discovery preview, manual fallback, validation, successful Test & Save, failed test not persisting, loading existing account, stale/refreshing/verified/unknown/error states, cancellation, and redaction.

- [ ] **Step 2: Run Xcode test RED**

Run: `xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64' -only-testing:SievePilotAppTests`

- [ ] **Step 3: Implement dependencies, observable model, and setup view**

Views invoke model methods only. Password remains in setup state only until stored; clearing/deleting account removes the Keychain item.

- [ ] **Step 4: Run GREEN plus validators**

```bash
bash Scripts/test-xcode-project-validator.sh
bash Scripts/validate-xcode-project.sh all
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64' -only-testing:SievePilotAppTests
```

- [ ] **Step 5: Commit**

```bash
git add SievePilotApp SievePilotAppTests SievePilot.xcodeproj README.md
git commit -m "feat: add SievePilot account setup"
```

### Task 7: Out-of-office menu UI and lifecycle refresh

**Files:**
- Create: `SievePilotApp/Views/OutOfOfficeView.swift`
- Create: `SievePilotApp/Views/AccountSettingsView.swift`
- Modify: `SievePilotApp/AppModel.swift`
- Modify: `SievePilotApp/SievePilotApp.swift`
- Modify: `SievePilotAppTests/AppModelTests.swift`
- Create: `SievePilotAppTests/OutOfOfficeFlowTests.swift`
- Modify: `README.md`

**Interfaces:**
- AppModel adds subject/message/expiry/time-zone fields, derived capability limitations, `saveAndActivate()`, `disable()`, acknowledgement, stale marking, and wake/network refresh hooks.

- [ ] **Step 1: Write failing model/UI-flow tests**

Cover verified on/off/expired labels, blank subject, non-empty message, future expiry, DST gap/repeated-time handling, missing `vacation`/`date`/`relational`, Save and Activate, Disable, conflict, unknown activation, persistent errors, manual Refresh, popover stale refresh, wake/reconnect stale marking, and no inferred success.

- [ ] **Step 2: Run RED**

Run: `xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64' -only-testing:SievePilotAppTests`

- [ ] **Step 3: Implement operational menu UI**

Match the approved compact popover design. Disable mutation controls during operations. Display verification timestamps and explicit capability limitations. Add Settings and Quit actions.

- [ ] **Step 4: Run GREEN/full verification**

```bash
bash Scripts/test-xcode-project-validator.sh
bash Scripts/validate-xcode-project.sh all
. "$HOME/.swiftly/env.sh"
swift test
swift package dump-package >/dev/null
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64'
xcodebuild build -project SievePilot.xcodeproj -scheme SievePilot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.build/Xcode"
codesign --verify --deep --strict .build/Xcode/Build/Products/Release/SievePilot.app
git diff --check
```

- [ ] **Step 5: Update documentation and commit**

README must describe setup, Keychain privacy, supported capabilities, safe-version behavior, conflict/unknown states, backups, and the fact that live interoperability requires user-supplied server access.

```bash
git add SievePilotApp SievePilotAppTests README.md
git commit -m "feat: ship out-of-office menu workflow"
```

### Task 8: Opt-in interoperability harness and release gate

**Files:**
- Create: `Tests/SievePilotCoreTests/Live/LiveManageSieveInteropTests.swift`
- Create: `docs/live-interoperability.md`
- Modify: `README.md`

**Interfaces:**
- No production API additions.
- Tests are skipped unless explicit process environment variables are supplied; they never load a home `.env` file.

- [ ] **Step 1: Add skipped-by-default interoperability tests**

Environment is read only from the current process: host, port, source domain/manual identity, username, password, and destructive-test opt-in. Non-destructive test proves connect/STARTTLS/identity/auth/capabilities/logout. Destructive test requires a second explicit flag and a dedicated account; it verifies binary script round-trips, candidate activation/read-back, rollback, and cleanup.

- [ ] **Step 2: Add operator documentation**

Document exact variables, dedicated-account warning, backup requirement, no `.env` loading, expected server capabilities, and cleanup behavior.

- [ ] **Step 3: Run default verification**

```bash
. "$HOME/.swiftly/env.sh"
swift test
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64'
git diff --check
```

Expected: live tests skip; all synthetic tests pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/SievePilotCoreTests/Live docs/live-interoperability.md README.md
git commit -m "test: add opt-in ManageSieve interoperability"
```
