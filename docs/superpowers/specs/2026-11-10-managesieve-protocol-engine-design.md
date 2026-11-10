# ManageSieve Protocol Engine Design

**Date:** 2026-11-10

## Intent

Build the security-critical, transport-independent ManageSieve protocol engine that SievePilot will later use over a live STARTTLS-capable socket. This phase establishes bounded parsing, legal state transitions, capability replacement, authentication gating, command framing, cancellation, and deterministic transcript tests before choosing a concrete live TLS backend.

## Goals

- Parse fragmented ManageSieve responses from raw bytes without assuming UTF-8 for literal script bodies.
- Enforce explicit plaintext, TLS-upgrade, encrypted, authenticated, and closed states.
- Require `STARTTLS` before authentication and script operations.
- Discard all pre-TLS capabilities and reacquire capabilities after TLS succeeds.
- Support SASL `PLAIN` and `LOGIN` only after the injected transport reports authenticated TLS.
- Implement framing for `CAPABILITY`, `STARTTLS`, `AUTHENTICATE`, `LISTSCRIPTS`, `GETSCRIPT`, `CHECKSCRIPT`, `PUTSCRIPT`, `SETACTIVE`, `DELETESCRIPT`, and `LOGOUT`.
- Bound line, literal, aggregate response, and capability counts.
- Support operation timeout and cancellation through injected deterministic control points.
- Emit structured, redacted diagnostic events without credentials, SASL payloads, or complete script bodies.
- Verify behavior with deterministic fake-transport transcript tests.

## Non-goals

- A concrete TCP, STARTTLS, or certificate-validation implementation.
- DNS SRV discovery or certificate identity derivation.
- Reading credentials from the user’s home-directory `.env` file.
- Keychain persistence, account settings, SwiftUI setup, or connection-status UI.
- Safe script versioning, optimistic concurrency, activation verification, rollback, or manifest persistence.
- Live-server, Dovecot, or interoperability tests.

## Security and credential constraints

- Unit tests use synthetic credentials only.
- The engine accepts credentials only as ephemeral authentication-call arguments and does not persist them.
- Passwords and encoded SASL payloads are never exposed to the logging interface.
- The repository must not read, copy, print, or commit the user’s home-directory `.env` file.
- A later live-adapter phase may use those credentials only after explicit authorization and must load them without echoing values.
- Authentication and script commands fail locally unless the state is encrypted and the post-TLS capabilities permit the requested operation.

## Approaches considered

### Selected: transport-independent protocol engine

Implement the parser and state machine over a narrow injected byte-transport interface. Fake transports deterministically drive fragmentation, errors, TLS transitions, cancellation, and dropped connections. A later phase chooses the live socket/TLS backend.

This keeps protocol policy independently testable and avoids committing to deprecated SecureTransport or a large third-party dependency before the wire behavior is settled.

### Rejected for this phase: SecureTransport socket implementation

SecureTransport supports in-place STARTTLS but is deprecated. Selecting it now would create maintenance debt before the protocol engine is independently proven.

### Rejected for this phase: SwiftNIO and NIOSSL

SwiftNIO can dynamically insert TLS handlers but adds substantial dependencies and operational surface. It remains a candidate for the live-adapter phase after dependency and interoperability review.

## Package structure

The implementation remains in the existing `SievePilotCore` package so it stays independent of SwiftUI and can run under `swift test`.

```text
Sources/SievePilotCore/ManageSieve/
  ManageSieveLimits.swift
  ManageSieveSyntax.swift
  ManageSieveResponseParser.swift
  ManageSieveCapabilities.swift
  ManageSieveTransport.swift
  ManageSieveTimer.swift
  ManageSieveLogger.swift
  ManageSieveClient.swift

Tests/SievePilotCoreTests/ManageSieve/
  ManageSieveResponseParserTests.swift
  ManageSieveCapabilityTests.swift
  ManageSieveClientStateTests.swift
  ManageSieveAuthenticationTests.swift
  ManageSieveCommandTests.swift
  ManageSieveBoundsAndCancellationTests.swift
  FakeManageSieveTransport.swift
```

Each production file has one responsibility: limits, syntax values, incremental parsing, capability interpretation, transport boundary, timeout boundary, redacted events, and client orchestration.

## Wire representation

### Strings

ManageSieve strings are represented as raw `Data` first. Quoted strings decode escaped quote and backslash bytes. Literals preserve their exact bytes and may contain invalid UTF-8. Callers explicitly request UTF-8 decoding only for protocol values that require text, such as capability names and script names.

The parser accepts:

- quoted strings with legal escaping and at most 1024 wire octets including quotes and escapes;
- server-to-client literals in the RFC 5804 form `{n}\r\n` only;
- status atoms `OK`, `NO`, and `BYE` case-insensitively;
- optional response codes and trailing strings;
- capability/data lines followed by a terminal status response.

Malformed quoting, server-sent `{n+}` literals, invalid literal lengths, arithmetic overflow, bare line feeds, unexpected tokens, and trailing garbage fail closed.

RFC 5804, including verified errata, is normative for ManageSieve grammar and state behavior. Its referenced base specifications are normative where incorporated: RFC 2244 for string syntax, RFC 4422 for SASL exchange rules, RFC 4616 for PLAIN, and `draft-murchison-sasl-login-00` for the obsolete but required LOGIN mechanism. No optional ManageSieve extension is implemented in this phase beyond tolerating unknown registered capability and response-code syntax as RFC 5804 requires.

### Incremental parsing

`ManageSieveResponseParser` owns a byte buffer and exposes a feed operation that returns zero or more complete response lines while retaining an incomplete suffix. The client groups data lines with the terminal status belonging to one command.

The parser never searches past configured bounds:

- maximum line length: 8 KiB of logical-line non-literal syntax, including literal headers but excluding CRLF delimiters and literal bodies;
- maximum literal length: 10 MiB;
- maximum aggregate response: 16 MiB, including all framing (CRLF delimiters, literal headers, and bodies);
- maximum capability/data lines per response: 256.

The limits are collected in `ManageSieveLimits` and may be lowered in tests, but production defaults cannot be silently increased by server input.

## Capabilities

`ManageSieveCapabilities` is derived from parsed response lines and normalizes capability names and SASL mechanism names case-insensitively while preserving unknown values for diagnostics.

Recognized values include:

- `STARTTLS`;
- `SASL` mechanisms;
- `SIEVE` extensions;
- `IMPLEMENTATION`;
- `VERSION`;
- `OWNER`;
- `LANGUAGE`;
- `NOTIFY` and unknown future capabilities.

Capabilities carry an origin: pre-TLS greeting or post-TLS `CAPABILITY`. The client never exposes pre-TLS SASL or Sieve extensions as authoritative. When TLS succeeds, the pre-TLS set is discarded before the post-TLS request is sent.

## Transport boundary

`ManageSieveTransport` is an injected `Sendable` reference-type protocol with asynchronous operations to:

- connect;
- read a bounded chunk;
- write bytes;
- upgrade the existing connection to TLS using a caller-supplied opaque identity request;
- close.

The protocol engine treats `upgradeToTLS` success as the only event that enters an encrypted state. The future live adapter is responsible for system trust and service-identity verification and must return failure before the engine can authenticate.

The fake transport uses scripted expected writes and queued reads. It can fragment any response at arbitrary byte boundaries, suspend operations, fail TLS, drop the connection, and record non-secret writes for assertions. Authentication payloads are compared inside the fake without including them in failure descriptions.

## Timeout and cancellation boundary

`ManageSieveOperationTimer` races an operation against one absolute deadline that does not reset when partial progress arrives. `ManageSieveTimeoutPolicy` supplies separate defaults for connection/greeting, STARTTLS and post-TLS capability acquisition, authentication, and ordinary commands; callers may override the relevant timeout per public operation. Production uses Swift concurrency sleeping, while tests inject a manually triggered timer so timeout behavior is deterministic.

The actor maintains an explicit operation-admission gate rather than relying on actor serialization across suspension points. A second operation attempted while one is admitted fails immediately with `operationInProgress` and sends no bytes. Cancellation before admission affects only that caller. Once an operation is admitted, cancellation closes the transport and moves the client to `closed`; timeout does the same. The engine does not retry commands automatically because replay safety differs by command.

## Client state machine

`ManageSieveClient` is an actor so commands cannot overlap on one connection.

States:

1. `disconnected`
2. `awaitingGreeting`
3. `plaintext` with unauthenticated greeting capabilities
4. `startingTLS`
5. `encryptedUnauthenticated` with no authoritative capabilities yet
6. `encryptedReady` with post-TLS capabilities
7. `authenticating`
8. `authenticated`
9. `closed`

Legal flow:

```text
disconnected
  -> awaitingGreeting
  -> plaintext
  -> startingTLS
  -> encryptedUnauthenticated
  -> encryptedReady
  -> authenticating
  -> authenticated
  -> closed
```

Any `BYE`, transport EOF, timeout, admitted-operation cancellation, parse failure, or TLS failure closes the client. A failed authentication returns to `encryptedReady` only when the server’s terminal response leaves the connection usable; `BYE` closes it. An explicit encrypted-state `CAPABILITY` refresh is transactional: terminal `OK` atomically replaces the authoritative set, terminal `NO` retains the previous set and state, and `BYE` closes.

Public operations validate state before writing. Calling authentication before TLS, script commands before authentication, a second command while one is active, or any command after close fails locally without sending bytes.

## Connection and STARTTLS flow

1. Connect the injected transport.
2. Read a bounded greeting ending in terminal `OK`; reject `NO`, `BYE`, malformed, or oversized greetings.
3. Parse and retain only the pre-TLS greeting capabilities.
4. Require `STARTTLS`; otherwise close with a downgrade error.
5. Send `STARTTLS\r\n` and require terminal `OK`.
6. Invoke `transport.upgradeToTLS(identity:)`.
7. On success, erase all pre-TLS capabilities.
8. Send `CAPABILITY\r\n` over TLS.
9. Parse and store the post-TLS capability set.
10. Enter `encryptedReady`.

A server that advertised SASL before TLS but omits it afterward cannot be authenticated. A server that changes Sieve extensions after TLS uses only the post-TLS values.

## Authentication

The caller chooses `PLAIN` or `LOGIN`; the engine does not silently downgrade to a different mechanism. The selected mechanism must appear in post-TLS `SASL` capabilities.

### PLAIN

Build the SASL message from authorization identity (empty in v1), authentication identity, and password separated by NUL bytes. Encode it as Base64 and frame it as a ManageSieve string. The raw and encoded values are scoped to the authentication operation and omitted from errors and logs.

### LOGIN

Follow `draft-murchison-sasl-login-00`: require exactly two ManageSieve SASL challenge strings, each encoded as valid Base64. Ignore the decoded prompt contents, because deployed servers use variants such as `User Name`, `Username:`, `Password`, and `Password:`. Respond positionally with Base64 username after the first challenge and Base64 password after the second. A terminal status before both challenges, a third challenge, invalid Base64, or any unexpected response fails authentication and closes when protocol synchronization is uncertain.

A terminal authentication `OK` proves the credentials but does not immediately expose the session as authenticated. Because PLAIN and LOGIN negotiate no SASL security layer and therefore do not carry RFC 5804’s optional automatic capability block, the client sends an explicit `CAPABILITY` command, validates the response, and atomically replaces the authoritative capability set. Only then does it enter `authenticated`. Failure to reacquire capabilities after successful authentication closes the connection because the server-side authentication state has changed but the client cannot safely characterize it. `NO` returns a typed authentication error without including server text if it could echo sensitive material. `BYE` closes.

## Commands

All command methods require `authenticated` except `CAPABILITY`, `STARTTLS`, `AUTHENTICATE`, and `LOGOUT`, whose legal states are explicit.

- `listScripts()` returns script names and active flags, rejecting duplicate active markers or malformed lines.
- `getScript(name:)` returns literal bytes exactly.
- `checkScript(_:)` sends script bytes using RFC 5804’s client-to-server non-synchronizing literal form `{n+}\r\n`, immediately followed by exactly `n` bytes and the command-terminating CRLF; there is no continuation wait.
- `putScript(name:script:)` sends the name plus the same `{n+}` literal framing without decoding or normalizing the script; there is no continuation wait.
- `setActive(name:)` supports an empty name for no active script.
- `deleteScript(name:)` sends a safely encoded script name.
- `capability()` refreshes authoritative capabilities only in encrypted states.
- `logout()` accepts terminal `OK` or `BYE`, then closes.

Client-generated protocol text uses CRLF exclusively. Script names reject NUL, CR, LF, and values that cannot be represented safely as a ManageSieve string.

## Errors

Typed errors distinguish:

- illegal state;
- malformed or oversized response;
- STARTTLS unavailable or rejected;
- TLS upgrade failure;
- post-TLS capability failure;
- unsupported authentication mechanism;
- authentication rejection or malformed challenge;
- server `NO` and `BYE` responses;
- transport EOF or I/O failure;
- timeout;
- cancellation.

Errors may include bounded sanitized protocol summaries, but never passwords, SASL payloads, or full script bodies.

## Logging

The logger receives structured event cases rather than raw strings. Events include connection state changes, command names, response status, byte counts, capability names, timeout, cancellation, and error category.

Authentication events identify only the mechanism. Script events include only script-name-safe metadata and byte counts. Full scripts, credentials, and Base64 authentication values are not loggable fields.

## Testing

Tests follow strict RED/GREEN cycles and use the fake transport.

### Parser tests

- every split point across quoted strings, CRLF, literal headers, and literal bodies;
- invalid UTF-8 inside literals remains byte-identical;
- malformed escapes, bare LF, overflow, oversized lines/literals/responses, and trailing garbage fail closed;
- multiple complete lines in one feed and incomplete suffix retention.

### Capability and state tests

- greeting must terminate correctly and advertise STARTTLS;
- authentication-before-TLS sends no bytes;
- pre-TLS SASL and Sieve values disappear after TLS;
- post-TLS capabilities become authoritative;
- TLS failure, `BYE`, timeout, cancellation, and EOF close the client;
- commands in wrong states send no bytes.

### Authentication tests

- PLAIN and LOGIN success followed by mandatory authenticated `CAPABILITY` refresh;
- unadvertised mechanism rejection before sending credentials;
- LOGIN accepts varied prompt contents but requires exactly two valid-Base64 challenges;
- malformed, missing, or extra LOGIN challenges;
- `NO` and `BYE` handling;
- logs and failure descriptions contain neither plaintext nor Base64 credentials.

### Command tests

- exact CRLF framing for every command, including immediate `{n+}` client literal transmission with no continuation read;
- raw script literal round-trip including invalid UTF-8;
- fragmented responses;
- malformed LISTSCRIPTS results;
- empty active-script name;
- server `NO` and `BYE` responses.

### Bounds and cancellation tests

- each configured bound at limit and one byte over;
- deterministic timeout at connect, greeting, TLS, authentication, and command stages;
- cancellation closes once and prevents future writes.

## Verification

- `swift test` must pass all existing and new package tests.
- `xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS,arch=arm64'` must continue to pass.
- Existing raw-byte Sieve behavior must remain unchanged.
- No test or source file may read the home-directory `.env`.

## Follow-on phase

After this engine is accepted, a separate design selects the live STARTTLS backend. That phase must prove system trust, SAN-only service-identity validation, SRV-derived identities, explicit manual-host identities, timeouts, cancellation, and real-server interoperability before the app is allowed to use home-directory credentials or Keychain values.
