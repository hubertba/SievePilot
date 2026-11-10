# ManageSieve Protocol Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a bounded, transport-independent ManageSieve parser and actor-based client that safely performs STARTTLS state transitions, post-TLS capability replacement, SASL PLAIN/LOGIN, and authenticated script commands over an injected byte transport.

**Architecture:** Add focused ManageSieve components to `SievePilotCore`: an incremental raw-byte parser, capability model, transport/timer/logger boundaries, and a stateful actor client. Deterministic fake-transport transcripts drive every security-sensitive state transition without reading local credentials or opening live network connections.

**Tech Stack:** Swift 5.9, Foundation, Swift Concurrency, Swift Testing, RFC 5804, RFC 4422, RFC 4616, `draft-murchison-sasl-login-00`

**Spec:** `docs/superpowers/specs/2026-11-10-managesieve-protocol-engine-design.md`

## Global Constraints

- Target macOS 13 or newer and preserve the existing `SievePilotCore` package boundary.
- Do not add external dependencies.
- Do not open live network connections or implement a concrete TLS backend.
- Never read, print, copy, or commit the user’s home-directory `.env` file.
- Tests use synthetic credentials only and must prove credentials and SASL payloads are absent from logs and failure descriptions.
- RFC 5804 plus verified errata is normative; use RFC 2244 string syntax, RFC 4422 SASL exchange rules, RFC 4616 PLAIN, and `draft-murchison-sasl-login-00` LOGIN.
- Client-generated wire text uses CRLF exclusively.
- Server-to-client literals accept `{n}` only; client-to-server script literals use `{n+}` and never wait for continuation.
- Production defaults: 8 KiB maximum line, 10 MiB maximum literal, 16 MiB aggregate response, and 256 data/capability lines.
- One absolute deadline applies per admitted operation and never resets on partial progress.
- Only one operation may be admitted at a time; overlap fails locally without writing.

## Review Focus

- Fragmentation at every byte boundary around quoted escapes, literal headers, CRLF, and literal bodies must produce the same result as an unfragmented response; Task 1 adds split-point tests.
- Stale pre-TLS SASL or Sieve capabilities must never authorize post-TLS behavior; Task 3 tests capability erasure and replacement.
- Credentials, Base64 SASL responses, and script bodies must never enter logs or error descriptions; Tasks 4 and 6 add sentinel-secret tests.
- A peer making slow partial progress must not extend an operation deadline; Task 6 tests one absolute manually triggered timeout.
- Actor reentrancy must not permit overlapping command writes; Task 6 tests immediate `operationInProgress` rejection while another operation is suspended.

---

### Task 1: Incremental ManageSieve wire parser

**Files:**
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveLimits.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveSyntax.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveResponseParser.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveResponseParserTests.swift`

**Interfaces:**
- Consumes: Foundation `Data` only.
- Produces: `ManageSieveLimits`, `ManageSieveToken`, `ManageSieveWireLine`, `ManageSieveResponseParser.feed(_:)`, and `finish()` for all later tasks.

- [ ] **Step 1: Write failing tests for fragmented quoted and atom lines**

Create `ManageSieveResponseParserTests` asserting that every split point of:

```text
"IMPLEMENTATION" "Dovecot Pigeonhole"\r\n
OK "ready"\r\n
```

produces two identical `ManageSieveWireLine` values with string tokens and a case-normalized status atom. Include escaped quote and backslash cases.

- [ ] **Step 2: Run parser tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveResponseParserTests`
Expected: FAIL because parser types do not exist.

- [ ] **Step 3: Implement limits, tokens, and quoted/atom incremental parsing**

Define:

```swift
public struct ManageSieveLimits: Equatable, Sendable
public enum ManageSieveToken: Equatable, Sendable
public struct ManageSieveWireLine: Equatable, Sendable
public struct ManageSieveResponseParser: Sendable {
    public mutating func feed(_ data: Data) throws -> [ManageSieveWireLine]
    public mutating func finish() throws
}
```

`ManageSieveToken` must represent atom, number, string bytes, and parenthesized token lists. Preserve string bytes as `Data`; normalize only recognized status comparisons, not arbitrary string bytes.

- [ ] **Step 4: Run quoted/atom tests to verify GREEN**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveResponseParserTests`
Expected: quoted and atom fragmentation tests pass.

- [ ] **Step 5: Write failing literal, list, and malformed-input tests**

Add tests for:

- every split point of `{5}\r\na\r\nbc\r\n`, preserving `a\r\nbc` exactly;
- invalid UTF-8 literal bytes;
- nested parenthesized response-code tokens;
- server `{5+}` rejection;
- bare LF, malformed escape, unterminated quote/list/literal, leading-zero literal length, UInt32 overflow, trailing garbage, and incomplete `finish()` rejection;
- line, literal, aggregate, and line-count limits exactly at limit and one byte over.

- [ ] **Step 6: Run new parser tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveResponseParserTests`
Expected: FAIL on missing literal/list/bound behavior.

- [ ] **Step 7: Implement literal, parenthesized-list, finish, and bounds behavior**

Use a byte-oriented state machine with checked integer arithmetic. Count aggregate bytes and completed lines against the injected `ManageSieveLimits`. Reject server non-synchronizing literals and never decode literal bodies.

- [ ] **Step 8: Run parser and full package suites**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter ManageSieveResponseParserTests
swift test
```

Expected: parser tests and all package tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve
git commit -m "feat: parse bounded ManageSieve responses"
```

### Task 2: Capability and response interpretation

**Files:**
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveCapabilities.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveResponse.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveCapabilityTests.swift`

**Interfaces:**
- Consumes: `[ManageSieveWireLine]` and `ManageSieveToken` from Task 1.
- Produces: `ManageSieveStatusResponse`, `ManageSieveCommandResponse`, `ManageSieveCapabilities`, and capability origin values used by the client.

- [ ] **Step 1: Write failing status and capability tests**

Test:

- case-insensitive `OK`, `NO`, and `BYE` terminal statuses;
- optional parenthesized response code and bounded human-readable string;
- unknown response codes preserved structurally;
- capability names and SASL/Sieve lists normalized case-insensitively;
- unknown capabilities preserved;
- duplicate singleton `IMPLEMENTATION`, `VERSION`, or `LANGUAGE` rejected;
- malformed capability arity rejected;
- authoritative capability validation requires `IMPLEMENTATION`, `VERSION`, `SASL`, and `SIEVE` after TLS.

- [ ] **Step 2: Run capability tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveCapabilityTests`
Expected: FAIL because interpretation types do not exist.

- [ ] **Step 3: Implement response grouping and capability interpretation**

Define:

```swift
public enum ManageSieveStatus: Equatable, Sendable { case ok, no, bye }
public struct ManageSieveStatusResponse: Equatable, Sendable
public struct ManageSieveCommandResponse: Equatable, Sendable
public enum ManageSieveCapabilityOrigin: Equatable, Sendable
public struct ManageSieveCapabilities: Equatable, Sendable
```

Group zero or more data lines with exactly one terminal status. Capability parsing accepts one or two string tokens per data line and provides case-insensitive query methods for capability, SASL mechanism, and Sieve extension membership.

- [ ] **Step 4: Run capability and full package suites**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter ManageSieveCapabilityTests
swift test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve/ManageSieveCapabilityTests.swift
git commit -m "feat: interpret ManageSieve capabilities"
```

### Task 3: Transport boundaries and STARTTLS state machine

**Files:**
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveTransport.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveTimer.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveLogger.swift`
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveClient.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/FakeManageSieveTransport.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveClientStateTests.swift`

**Interfaces:**
- Consumes: parser and capability types from Tasks 1–2.
- Produces: `ManageSieveTransport`, `ManageSieveTLSIdentityRequest`, `ManageSieveClock`, `ManageSieveTimeoutPolicy`, `ManageSieveLogEvent`, `ManageSieveClient`, and public state/error types.

- [ ] **Step 1: Write failing happy-path STARTTLS transcript test**

The fake transport transcript must require:

1. connect;
2. fragmented greeting advertising `STARTTLS` plus untrusted pre-TLS `SASL` and `SIEVE` values;
3. exact write `STARTTLS\r\n`;
4. terminal `OK`;
5. successful fake TLS upgrade with the supplied identity request;
6. exact encrypted write `CAPABILITY\r\n`;
7. fragmented post-TLS capabilities and terminal `OK`.

Assert final state `encryptedReady`, pre-TLS values absent, and post-TLS values authoritative.

- [ ] **Step 2: Run state tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveClientStateTests`
Expected: FAIL because transport/client types do not exist.

- [ ] **Step 3: Implement transport, clock, logger, errors, and minimal client handshake**

Define:

```swift
public protocol ManageSieveTransport: AnyObject, Sendable {
    func connect() async throws
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) async throws
    func close() async
}

public struct ManageSieveTLSIdentityRequest: Equatable, Sendable {
    public let referenceIdentifiers: [String]
}

public protocol ManageSieveClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ManageSieveTimeoutPolicy: Equatable, Sendable {
    public let connect: Duration
    public let startTLS: Duration
    public let authentication: Duration
    public let command: Duration
}

public enum ManageSieveLogEvent: Equatable, Sendable
public protocol ManageSieveLogger: Sendable {
    func record(_ event: ManageSieveLogEvent)
}

public actor ManageSieveClient {
    public init(
        transport: any ManageSieveTransport,
        clock: any ManageSieveClock,
        timeoutPolicy: ManageSieveTimeoutPolicy,
        limits: ManageSieveLimits,
        logger: any ManageSieveLogger
    )

    public func connectAndStartTLS(
        identity: ManageSieveTLSIdentityRequest,
        timeout: Duration? = nil
    ) async throws -> ManageSieveCapabilities
}
```

Use an explicit admitted-operation flag before the first suspension. Reject an empty identity list locally. Erase pre-TLS capabilities immediately after TLS upgrade and before writing `CAPABILITY`.

- [ ] **Step 4: Run happy-path state test to verify GREEN**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveClientStateTests`
Expected: happy-path transcript passes.

- [ ] **Step 5: Write failing downgrade and transition tests**

Cover:

- greeting `NO`, `BYE`, malformed, oversized, missing `STARTTLS`, or EOF;
- STARTTLS `NO`/`BYE`;
- TLS upgrade failure;
- malformed/missing post-TLS capabilities;
- every failure closes exactly once;
- authentication and script operations before their legal states send no bytes;
- command after close fails locally;
- explicit encrypted capability refresh atomically replaces on `OK`, retains old values on `NO`, and closes on `BYE`.

- [ ] **Step 6: Run transition tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveClientStateTests`
Expected: FAIL on unimplemented failure transitions and refresh behavior.

- [ ] **Step 7: Implement failure transitions and transactional capability refresh**

Expose a read-only state snapshot and `capability()` only in encrypted states. Map parse, transport, timeout, TLS, server `NO`, and `BYE` failures to typed errors without raw response bodies.

- [ ] **Step 8: Run state and full package suites**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter ManageSieveClientStateTests
swift test
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve
git commit -m "feat: enforce ManageSieve STARTTLS state"
```

### Task 4: SASL PLAIN and LOGIN authentication

**Files:**
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveAuthentication.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveAuthenticationTests.swift`
- Modify: `Sources/SievePilotCore/ManageSieve/ManageSieveClient.swift`
- Modify: `Tests/SievePilotCoreTests/ManageSieve/FakeManageSieveTransport.swift`

**Interfaces:**
- Consumes: `ManageSieveClient` in `encryptedReady` and post-TLS capabilities.
- Produces:

```swift
public func authenticatePlain(
    username: String,
    password: String,
    timeout: Duration? = nil
) async throws

public func authenticateLogin(
    username: String,
    password: String,
    timeout: Duration? = nil
) async throws
```

and authenticated state plus typed authentication errors.

- [ ] **Step 1: Write failing PLAIN success and gating tests**

Assert:

- unadvertised `PLAIN` fails before any credential write;
- advertised `PLAIN` writes `AUTHENTICATE "PLAIN" "<base64>"\r\n` with RFC 4616 `NUL + username + NUL + password` bytes;
- terminal authentication `OK` triggers exact write `CAPABILITY\r\n`, and only a valid capability response enters authenticated state;
- failed or malformed post-authentication capability reacquisition closes;
- terminal `NO` returns to `encryptedReady`;
- `BYE` closes;
- NUL in username/password fails locally; PLAIN accepts valid UTF-8 values without imposing a narrower client-side limit than RFC 4616.

The fake may compare the expected Base64 payload internally, but test failure output must not print it.

- [ ] **Step 2: Run authentication tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveAuthenticationTests`
Expected: FAIL because authentication methods do not exist.

- [ ] **Step 3: Implement PLAIN**

Build credential bytes in operation-local `Data`, frame them through the safe quoted-string encoder, and release references after the operation. After authentication `OK`, explicitly reacquire and atomically replace capabilities before entering authenticated state. Log only `.authenticationStarted(mechanism: "PLAIN")` and status/category events.

- [ ] **Step 4: Run PLAIN tests to verify GREEN**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveAuthenticationTests`
Expected: PLAIN tests pass.

- [ ] **Step 5: Write failing LOGIN transcript tests**

Test:

- exact initial write `AUTHENTICATE "LOGIN"\r\n`;
- two syntactically valid Base64 challenge strings with arbitrary decoded prompt contents;
- positional Base64 username then password responses;
- terminal authentication `OK` followed by mandatory authenticated capability refresh;
- terminal response before two challenges, invalid Base64, third challenge, `NO`, and `BYE` behavior;
- unsupported LOGIN rejected before sending credentials;
- LOGIN rejects usernames of 64 or more characters and passwords containing NUL, CR, or LF as required by the obsolete mechanism draft.

- [ ] **Step 6: Run LOGIN tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveAuthenticationTests`
Expected: FAIL on missing LOGIN behavior.

- [ ] **Step 7: Implement LOGIN and secret-redaction guarantees**

Accept exactly two valid-Base64 server challenge strings and ignore decoded prompt text. Add a sentinel test that searches every recorded event and every error description for plaintext and Base64 username/password values and finds none.

- [ ] **Step 8: Run authentication and full package suites**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter ManageSieveAuthenticationTests
swift test
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve
git commit -m "feat: authenticate ManageSieve sessions"
```

### Task 5: Authenticated script commands and literal framing

**Files:**
- Create: `Sources/SievePilotCore/ManageSieve/ManageSieveCommands.swift`
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveCommandTests.swift`
- Modify: `Sources/SievePilotCore/ManageSieve/ManageSieveClient.swift`
- Modify: `Tests/SievePilotCoreTests/ManageSieve/FakeManageSieveTransport.swift`

**Interfaces:**
- Consumes: authenticated `ManageSieveClient`, parser, and response models.
- Produces:

```swift
public func listScripts(timeout: Duration? = nil) async throws -> [ManageSieveScriptEntry]
public func getScript(name: String, timeout: Duration? = nil) async throws -> Data
public func checkScript(_ script: Data, timeout: Duration? = nil) async throws -> ManageSieveCommandResult
public func putScript(name: String, script: Data, timeout: Duration? = nil) async throws -> ManageSieveCommandResult
public func setActive(name: String, timeout: Duration? = nil) async throws
public func deleteScript(name: String, timeout: Duration? = nil) async throws
public func capability(timeout: Duration? = nil) async throws -> ManageSieveCapabilities
public func logout(timeout: Duration? = nil) async throws
```

plus script-list/result types.

- [ ] **Step 1: Write failing command-encoding and simple-command tests**

Test exact writes and typed responses for:

```swift
listScripts()
getScript(name: String)
setActive(name: String)
deleteScript(name: String)
logout()
```

Cover quoted name escaping, empty name only for `SETACTIVE`, NUL/CR/LF rejection, non-ASCII UTF-8 names, fragmented reads, server `NO`, and `BYE`. `LISTSCRIPTS` rejects malformed lines, duplicate names, or more than one active marker.

- [ ] **Step 2: Run command tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveCommandTests`
Expected: FAIL because command methods do not exist.

- [ ] **Step 3: Implement safe string encoding and simple commands**

Define:

```swift
public struct ManageSieveScriptEntry: Equatable, Sendable
public struct ManageSieveCommandResult: Equatable, Sendable
```

Encode script names as quoted strings when their escaped form fits RFC 5804’s 1024-octet quoted-string bound; otherwise use a client `{n+}` literal. Preserve `GETSCRIPT` literal bytes exactly. `logout()` accepts terminal `OK` or `BYE` and always closes.

- [ ] **Step 4: Run simple-command tests to verify GREEN**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveCommandTests`
Expected: simple-command tests pass.

- [ ] **Step 5: Write failing CHECKSCRIPT and PUTSCRIPT literal tests**

For scripts including invalid UTF-8 and embedded CRLF, require exact framing:

```text
CHECKSCRIPT {n+}\r\n<n raw bytes>\r\n
PUTSCRIPT "name" {n+}\r\n<n raw bytes>\r\n
```

Assert no read occurs between literal header and body, zero-length script rejection, 10 MiB bound, warning response preservation, and no script body in events/errors.

- [ ] **Step 6: Run literal-command tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveCommandTests`
Expected: FAIL on missing literal command behavior.

- [ ] **Step 7: Implement CHECKSCRIPT and PUTSCRIPT**

Compute literal length from raw bytes with checked conversion, write header/body/terminating CRLF as one logical admitted operation, and interpret terminal status plus warning response codes.

- [ ] **Step 8: Run command and full package suites**

Run:

```bash
. "$HOME/.swiftly/env.sh"
swift test --filter ManageSieveCommandTests
swift test
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve
git commit -m "feat: add ManageSieve script commands"
```

### Task 6: Timeout, cancellation, overlap, and final verification

**Files:**
- Create: `Tests/SievePilotCoreTests/ManageSieve/ManageSieveBoundsAndCancellationTests.swift`
- Modify: `Sources/SievePilotCore/ManageSieve/ManageSieveClient.swift`
- Modify: `Sources/SievePilotCore/ManageSieve/ManageSieveTimer.swift`
- Modify: `Sources/SievePilotCore/ManageSieve/ManageSieveLogger.swift`
- Modify: `Tests/SievePilotCoreTests/ManageSieve/FakeManageSieveTransport.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: all protocol-engine behavior from Tasks 1–5.
- Produces: deterministic lifecycle guarantees, documented scope, and final verified package/Xcode integration.

- [ ] **Step 1: Write failing deterministic timeout tests**

Using a manually triggered fake clock, suspend at connect, greeting read, STARTTLS response, TLS upgrade, post-TLS capability read, authentication challenge, and authenticated command response. Trigger the one absolute deadline and assert typed timeout, exactly one close, and no later writes. Include slow partial fragments that do not reset the deadline.

- [ ] **Step 2: Run lifecycle tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveBoundsAndCancellationTests`
Expected: FAIL on incomplete timer integration.

- [ ] **Step 3: Implement absolute operation deadlines**

Race each admitted operation against `ManageSieveClock.sleep(for:)` using the timeout selected from `ManageSieveTimeoutPolicy`. Ensure timer-task cancellation cannot close a successfully completed operation.

- [ ] **Step 4: Run timeout tests to verify GREEN**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveBoundsAndCancellationTests`
Expected: timeout tests pass.

- [ ] **Step 5: Write failing cancellation and overlap tests**

Test:

- a second operation attempted while the first is suspended fails immediately with `operationInProgress` and sends no bytes;
- cancellation after admission closes exactly once and prevents future writes;
- cancellation before admission affects only that caller and leaves the active connection untouched;
- transport completion racing cancellation produces one terminal outcome and one close at most;
- all events/errors omit credential, Base64 credential, and script-body sentinels.

- [ ] **Step 6: Run cancellation/overlap tests to verify RED**

Run: `. "$HOME/.swiftly/env.sh" && swift test --filter ManageSieveBoundsAndCancellationTests`
Expected: FAIL on missing admission/cancellation race handling.

- [ ] **Step 7: Implement cancellation-safe admission and final redaction**

Use one actor-owned admission token per operation and a cancellation handler that closes only when that token was admitted. Keep logger event payloads to states, command names, mechanisms, status categories, capability names, safe script names, and byte counts.

- [ ] **Step 8: Document protocol-engine scope**

Update `README.md` to state that the parser and fake-transport protocol engine are implemented, while live TCP/TLS, account setup, and `.env`/Keychain credential loading remain deferred.

- [ ] **Step 9: Run all verification**

Run:

```bash
bash Scripts/test-xcode-project-validator.sh
bash Scripts/validate-xcode-project.sh all
. "$HOME/.swiftly/env.sh"
swift test
swift package dump-package >/dev/null
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64'
git diff --check
```

Expected: validator mutation suite passes, all package tests pass, app XCTest passes, manifest parses, and diff check is clean.

- [ ] **Step 10: Commit**

```bash
git add Sources/SievePilotCore/ManageSieve Tests/SievePilotCoreTests/ManageSieve README.md docs/superpowers/specs/2026-11-10-managesieve-protocol-engine-design.md docs/superpowers/plans/2026-11-10-managesieve-protocol-engine.md
git commit -m "test: harden ManageSieve protocol lifecycle"
```
