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
- Create: `Package.resolved`

**Interfaces:**
- Consumes: existing `ManageSieveTransport` and `ManageSieveTLSIdentityRequest`.
- Produces:

```swift
public final class NIOManageSieveTransport: ManageSieveTransport, @unchecked Sendable {
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: Int
    }

    public init(endpoint: Endpoint, eventLoopGroup: (any EventLoopGroup)? = nil)
}
```

- [ ] **Step 1: Add package dependencies and write failing plain-TCP transport tests**

Add explicit mutually compatible package ranges for `swift-nio`, `swift-nio-ssl`, and `swift-certificates`; link `NIOCore`, `NIOPosix`, `NIOSSL`, and `X509` to `SievePilotCore`, resolve them, and commit `Package.resolved`. Tests use a loopback `ServerBootstrap` and assert connect, fragmented reads, bounded read splitting, ordered writes, EOF, connect failure, pending connect/read/write release, idempotent close, external event-loop-group non-ownership, and no byte-bearing error descriptions.

- [ ] **Step 2: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter NIOManageSieveTransportTests`
Expected: FAIL because the transport does not exist.

- [ ] **Step 3: Implement the actor-protected channel bridge**

Use one lifecycle state machine and waiter registry serialized on the channel event loop or behind one lock/actor. `read(maxBytes:)` returns at most the requested count and retains a suffix. `write(_:)` completes after `writeAndFlush`. `close()` atomically marks closed, resumes pending connect/read/write continuations exactly once, closes the channel, and shuts down only an internally owned event-loop group.

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
git add Package.swift Package.resolved Sources/SievePilotCore/Live Tests/SievePilotCoreTests/Live
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

public protocol TLSChainTrustEvaluating: Sendable {
    func evaluate(certificateChainDER: [Data]) async throws
}

public struct ManageSieveTLSIdentityValidator: Sendable {
    public func validate(
        certificateChain: [Certificate],
        identifiers: [ManageSieveReferenceIdentifier]
    ) throws
}
```

`SecurityTLSChainTrustEvaluator` uses Security.framework and macOS system trust. Swift Certificates parses SAN extensions and performs DNS-ID/SRV-ID matching only. Update `ManageSieveTLSIdentityRequest` to carry typed identifiers and migrate all existing call sites; do not retain an ambiguous `[String]` production initializer.

- [ ] **Step 1: Write failing pure identity tests**

Cover exact DNS SAN, ASCII case folding, valid leftmost wildcard, forbidden partial/multi-label wildcard, SAN-only behavior, malformed names, no Common Name fallback, source-domain DNS-ID success, SRV-ID success, discovered-target-only rejection, expired/untrusted chain rejection, and empty identifiers.

- [ ] **Step 2: Run identity RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveTLSIdentityValidatorTests`
Expected: FAIL on missing validator/types.

- [ ] **Step 3: Implement chain and SAN validation**

Use Security.framework `SecTrust` evaluation for the production macOS system chain trust decision. Use Swift Certificates only for deterministic fixture-chain tests and SAN parsing/matching. Match DNS-ID and SRV-ID (`otherName` OID `1.3.6.1.5.5.7.8.7`) explicitly; the connection target is never added to identifiers implicitly. Keep public TLS errors sanitized but distinguish chain-trust from service-identity failure.

- [ ] **Step 4: Write failing STARTTLS pipeline tests**

Use a loopback NIO server with a plaintext greeting/STARTTLS response followed by TLS. Assert insertion on the existing channel, successful encrypted reads/writes, handshake failure, identity mismatch, cancellation, close during handshake, and no post-failure writes. Include a delivery that coalesces `OK\r\n` and the first TLS record, plus fragmented TLS records.

- [ ] **Step 5: Implement `upgradeToTLS(identity:)`**

Serialize upgrade on the channel event loop. Pause application delivery at the exact plaintext response boundary, insert `NIOSSLClientHandler` before the application inbound bridge, and replay any already-buffered post-response bytes through the TLS handler. Complete only after handshake plus injected Security.framework chain trust and typed service-identity validation succeed. Any failure closes the channel and releases pending operations.

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
public struct SieveSRVRecord: Equatable, Sendable {
    public let priority: UInt16
    public let weight: UInt16
    public let port: UInt16
    public let target: String
}

public struct SieveServiceEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let referenceIdentifiers: [ManageSieveReferenceIdentifier]
}

public protocol SieveSRVResolving: Sendable {
    func records(for name: String) async throws -> [SieveSRVRecord]
}

public protocol SieveRandomSource: Sendable {
    func next(upperBound: UInt64) -> UInt64
}

public struct SieveServiceDiscovery: Sendable {
    public init(resolver: any SieveSRVResolving, random: any SieveRandomSource)
    public func discover(emailAddress: String) async throws -> SieveServiceEndpoint
}
```

- [ ] **Step 1: Write failing discovery tests**

Cover last-`@` email/domain validation, canonical ASCII source domain, exact `_sieve._tcp.<domain>` query, lowest-priority selection, canonical ordering before a `0..<upperBound` injected draw, positive-weight cumulative selection, uniform all-zero selection, checked weight sums, trailing-dot normalization, invalid labels/target/port zero, explicit no-service target `.`, timeout/cancellation, duplicate/add-remove callbacks, no records, and identifiers ordered as `.srv(service: "sieve", domain:)` then source-domain `.dns`, never target DNS-ID.

- [ ] **Step 2: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter SieveServiceDiscoveryTests`

- [ ] **Step 3: Implement injected selection and production DNSService resolver**

Wrap DNSService callbacks in one lock/actor-owned terminal state. Complete the first callback batch when `kDNSServiceFlagsMoreComing` clears, or on timeout/cancellation/error; deallocate the `DNSServiceRef` exactly once. Bound record count and cumulative RDATA bytes, parse SRV RDATA manually, and add the required DNS-SD linker setting. Discovery returns one endpoint; manual configuration is represented separately by Task 4.

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
- Create: `Sources/SievePilotCore/Account/AccountPersistenceCoordinator.swift`
- Modify: `Sources/SievePilotCore/Domain/AccountID.swift`
- Create: `Tests/SievePilotCoreTests/Account/KeychainCredentialStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public enum AccountEndpointPolicy: Equatable, Codable, Sendable {
    case automatic(sourceDomain: String)
    case manual(host: String, port: Int)
}

public enum AccountTLSPolicy: String, Codable, Sendable { case startTLS }

public struct AccountConfiguration: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public var emailAddress: String
    public var username: String
    public var endpointPolicy: AccountEndpointPolicy
    public var tlsPolicy: AccountTLSPolicy
}

public protocol AccountConfigurationStoring: Sendable {
    func load() async throws -> AccountConfiguration?
    func save(_ configuration: AccountConfiguration) async throws
    func delete() async throws
}

public protocol CredentialStoring: Sendable {
    func read(accountID: AccountID) async throws -> Data?
    func write(_ password: Data, accountID: AccountID) async throws
    func delete(accountID: AccountID) async throws
}

public actor AccountPersistenceCoordinator {
    public func save(configuration: AccountConfiguration, password: Data) async throws
    public func delete(accountID: AccountID) async throws
}
```

- [ ] **Step 1: Write failing validation/persistence tests**

Cover explicit tagged schema-v1 JSON, atomic replacement preserving previous bytes on failure, corrupt/unknown-version fail-closed behavior, no secret fields in JSON, email/username/manual endpoint validation, fixed `.startTLS`, and stable account IDs encoded as lowercase UUID strings.

- [ ] **Step 2: Write failing Keychain-boundary tests**

Inject a `SecurityClient` wrapper and assert generic-password query attributes, update-vs-add behavior, duplicate handling, not-found behavior, deletion, redacted errors, and temporary password-buffer wiping. Add an opt-in integration test guarded by `SIEVEPILOT_KEYCHAIN_INTEGRATION=1` using a random service and guaranteed cleanup; it must use synthetic data only.

- [ ] **Step 3: Run RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter 'AccountConfigurationStoreTests|KeychainCredentialStoreTests'`

- [ ] **Step 4: Implement settings and Keychain stores**

Store one fixed v1 settings file under an injected Application Support base directory: app directory mode `0700`, final JSON mode `0600`, same-directory temporary write plus atomic rename/replace. The coordinator snapshots prior configuration and credential, writes the new credential, then settings; on settings failure it restores the prior credential or deletes only when no prior item existed. Rollback failure returns a distinct inconsistent-state error. Delete settings first so the account becomes unusable, then delete the credential with explicit failure reporting.

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
public protocol AuthenticatedManageSieveSession: Sendable {
    var capabilities: ManageSieveCapabilities { get async }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry]
    func getScript(name: String, timeout: Duration?) async throws -> Data
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func setActive(name: String, timeout: Duration?) async throws
    func deleteScript(name: String, timeout: Duration?) async throws
}

public protocol ManageSieveSessionProviding: Sendable {
    func withAuthenticatedSession<T: Sendable>(
        account: AccountConfiguration,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T
    ) async throws -> T
}

public struct VerifiedAccountSnapshot: Equatable, Sendable {
    public let activeScriptName: String?
    public let activeScript: Data?
    public let outOfOfficeState: VerifiedOutOfOfficeState
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

Cover raw-byte baseline digest, candidate patching with fresh `ManagedScriptMetadata`, optional `CHECKSCRIPT` only when the ManageSieve `CHECKSCRIPT` capability is advertised, cryptographically random owned name collision retry against all names, `PUTSCRIPT`, repeated active-name plus byte-digest baseline check, conflict before activation, the documented unavoidable final `SETACTIVE` race, read-back verification, interruption returning unknown, quota/NO, no overwrite of any existing name, prepared/uploaded/verified manifest states, rollback eligibility, manifest-write failure after activation returning unknown, and conservative retention after manifest loss.

- [ ] **Step 5: Implement repository and manifest**

Use the closure-based session provider, injected clock, random bytes, and stores. SHA-256 uses CryptoKit over raw `Data`. Serialize per-account mutations in the service actor. Persist a prepared manifest record before upload, uploaded state after upload, and verified-active state only after active-name plus byte-identical read-back. Every mutation starts with refresh and returns success only after verification; optimistic concurrency cannot eliminate the final protocol race and must never be described as atomic.

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
- Create: `SievePilotApp/AppLifecycleCoordinator.swift`
- Modify: `SievePilotApp/SievePilotApp.swift`
- Modify: `Scripts/validate_xcode_project.py`
- Rewrite: `SievePilotAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: account coordinator, discovery, session factory, and account service protocols.
- Produces an `@MainActor final class AppModel: ObservableObject` with `@Published` setup form fields, persisted-account state, operation state, verified snapshot, persistent user-facing error, `load()`, `testAndSave()`, `refresh()`, and `deleteAccount()`. Its injected initializer accepts account/session/service protocols plus clock, calendar/time-zone, and lifecycle boundaries.

- [ ] **Step 1: Write failing app-model tests**

Cover first run, automatic discovery preview, manual fallback, validation, successful Test & Save, failed test not persisting, loading existing account, stale/refreshing/verified/unknown/error states, cancellation, and redaction.

- [ ] **Step 2: Run Xcode test RED**

Run: `xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64' -only-testing:SievePilotAppTests`

- [ ] **Step 3: Implement dependencies, observable model, and setup view**

Views invoke model methods only. Password remains in setup state only until stored; clearing/deleting account removes the Keychain item. Use cancellable operation tasks plus generation tokens so stale completions cannot overwrite newer state. Add every new app/test source to explicit PBX groups/build phases and extend the project validator accordingly.

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

Cover verified on/off/expired labels, blank subject, non-empty message, future expiry, DST gap/repeated-time handling, missing `vacation`/`date`/`relational`, Save and Activate, Disable, conflict, unknown activation, persistent errors, manual Refresh, coalesced popover-open refresh, wake/reconnect stale marking, stale-generation suppression, and no inferred success.

- [ ] **Step 2: Run RED**

Run: `xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64' -only-testing:SievePilotAppTests`

- [ ] **Step 3: Implement operational menu UI**

Match the approved compact popover design. Disable mutation controls during operations. Display verification timestamps and explicit capability limitations. Add Settings and Quit actions. Production lifecycle coordination uses `NSWorkspace.didWakeNotification` and a network-path monitor behind an injected protocol; it marks state stale immediately and coalesces refreshes. These are host-app/model tests, not UI-automation claims.

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
