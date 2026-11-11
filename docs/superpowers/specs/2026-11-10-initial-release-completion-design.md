# SievePilot Initial Release Completion Design

**Date:** 2026-11-10  
**Status:** Proposed  
**Builds on:** `2026-04-24-sievepilot-design.md` and `2026-11-10-managesieve-protocol-engine-design.md`

## Intent

Complete the first usable SievePilot release: a native menu-bar app that configures one email account, stores its password in Keychain, connects to a real ManageSieve server over authenticated TLS, safely reads and versions the active Sieve script, and exposes verified out-of-office controls.

The existing raw-byte rule engine and transport-independent ManageSieve client remain the security and protocol core. This phase supplies the live boundaries and application orchestration around them.

## Goals

- Connect to real ManageSieve servers using TCP followed by mandatory `STARTTLS`.
- Validate system trust and the configured service identity with no bypass.
- Discover `_sieve._tcp` service records and support explicit manual host/port configuration.
- Store one account's non-secret settings in a versioned local model and its password in macOS Keychain.
- Authenticate with post-TLS advertised SASL `PLAIN` or `LOGIN`.
- Refresh and display verified server state rather than inferring state from prior UI actions.
- Safely create, validate, upload, concurrency-check, activate, and verify owned script versions.
- Provide the designed menu-bar setup and out-of-office UI.
- Preserve all user-owned script bytes and never overwrite a user-named script in place.

## Non-goals

- Folder sorting, a general Sieve editor, OAuth, multi-account UI, App Store distribution, automatic updates, or a background scheduler.
- Reading credentials from the developer's home `.env` file.
- Trust-bypass controls or plaintext authentication.
- Implicit TLS in the first implementation slice. The account model may reserve the policy value, but the UI initially enables only STARTTLS until an independently tested implicit-TLS path exists.

## Approaches

### SwiftNIO + NIOSSL — selected

Use SwiftNIO for socket/event-loop lifecycle and NIOSSL for an in-place TLS handler inserted after the server accepts `STARTTLS`. This is the maintained approach with explicit pipeline control, deterministic embedded-channel tests, system-root loading, and clean adaptation to the existing async byte-transport protocol.

Trade-offs: two external package dependencies, a bridge from event-loop futures to Swift concurrency, and explicit certificate identity policy code.

### URLSessionStreamTask — rejected

It provides an Apple-only `startSecureConnection()` API but is deprecated and is a poor long-term security boundary.

### POSIX sockets + SecureTransport — rejected

It avoids package dependencies but relies on deprecated TLS APIs and requires substantially more custom security-critical socket and handshake code.

## Architecture

### 1. Live transport package boundary

Add SwiftNIO and NIOSSL package products to `SievePilotCore`. `NIOManageSieveTransport` implements the existing `ManageSieveTransport` protocol:

- `connect()` creates one `ClientBootstrap` TCP channel.
- `read(maxBytes:)` drains a bounded actor-owned inbound queue and suspends when empty.
- `write(_:)` writes and flushes one `ByteBuffer` and resumes only after completion.
- The protocol client reads the short STARTTLS terminal response with one-byte transport reads so any coalesced TLS bytes remain as an exact unread suffix inside the transport. `upgradeToTLS(identity:)` inserts `NIOSSLClientHandler` into the existing channel pipeline, replays that suffix through TLS, waits for the handshake, then performs explicit trust and service-identity validation.
- `close()` is idempotent, closes the channel/event-loop resources owned by the transport, and resumes all pending reads/writes with a closed error.

The transport must not log inbound or outbound bytes. Its errors expose categories and bounded technical metadata only.

### 2. TLS trust and service identity

NIOSSL performs the in-place handshake and exposes the peer chain through a custom verification callback. A Security.framework trust evaluator validates that chain against the macOS system trust store; Swift Certificates parses SAN extensions for a separate service-identity validator:

- manual host configuration supplies one explicit DNS-ID;
- SRV discovery supplies `_sieve.<source-domain>` as an SRV-ID and the source domain as a DNS-ID;
- the discovered target hostname is not automatically trusted;
- matching is ASCII case-insensitive, follows DNS wildcard restrictions, and never falls back to Common Name;
- any malformed SAN, absent required identity, trust failure, or mismatch closes the connection.

Identity parsing and matching are pure functions with synthetic certificate/SAN fixtures. Live credentials are not needed for tests.

### 3. Discovery and account persistence

`SieveServiceDiscovery` resolves `_sieve._tcp.<email-domain>` through an injected resolver. Production uses DNSService APIs; tests use deterministic records. Selection honors priority and weighted choice through an injected random source, rejects invalid ports/targets, and returns both the connection endpoint and source-domain reference identifiers.

`AccountConfiguration` is a versioned Codable model containing stable `AccountID`, email address, auth username, source domain, discovered/manual endpoint, and TLS policy. V1 stores one account in Application Support through an atomic file replacement.

`KeychainCredentialStore` uses Security.framework generic-password items keyed by stable account ID within a fixed SievePilot service namespace; mutable endpoint settings are not credential identity. Password data is operation-local, never included in errors, and overwritten where mutable client-owned buffers permit.

### 4. Authenticated session factory

`ManageSieveSessionFactory` composes discovery/manual endpoint selection, `NIOManageSieveTransport`, the existing `ManageSieveClient`, Keychain credentials, and timeout policy. It returns only an authenticated client with authoritative post-authentication capabilities.

Every app operation uses a fresh connection. Logout/close occurs in `defer`; there is no long-lived idle socket in v1.

### 5. Safe script repository

`SieveAccountService` owns refresh and mutation workflows:

- refresh lists scripts, fetches the active script as `Data`, evaluates managed state, and returns a timestamped verified snapshot;
- mutation refreshes immediately before editing, records active name/bytes/digest, patches only owned ranges, and validates with `CHECKSCRIPT` when advertised;
- it creates a cryptographically random owned version name, uploads it, repeats baseline checks, activates it, and reads it back byte-for-byte;
- detected changes stop before activation and return conflict;
- interrupted activation returns unknown until the next refresh resolves it;
- prior versions and the initial baseline remain available; pruning is conservative and deferred unless ownership metadata and local manifest agree.

A versioned local manifest records ownership, digests, predecessor relationships, and the last verified outcome.

### 6. Application model and UI

Replace the static `AppModel` with an `@MainActor` observable model injected with account, credential, discovery, and account-service interfaces.

Menu states:

- **No account:** email, username, password, automatic discovery, and manual host/port fallback; Test & Save.
- **Loading/refreshing:** progress with controls disabled.
- **Ready:** account/server summary, verification timestamp, verified out-of-office state, subject, message, expiry date/time/time zone, Refresh, Save and Activate, Disable, and Settings.
- **Unsupported:** explicit missing capability explanation.
- **Unknown/conflict/error:** persistent diagnostic banner and recovery action; never display a guessed on/off state.

Opening the popover refreshes server state when stale. Wake/network reconnection hooks mark state stale and trigger a refresh when practical. UI views contain no networking or script-generation logic.

## Data flow

1. User enters account data and password.
2. Discovery/manual endpoint selection determines connection target and reference identities.
3. Session factory connects, performs STARTTLS, validates trust/identity, authenticates, and returns capabilities.
4. On Test & Save success, non-secret configuration and Keychain password are persisted.
5. Refresh fetches active server bytes and derives one verified UI state.
6. Save/Disable constructs a candidate from the refreshed baseline, validates, uploads a new owned version, concurrency-checks, activates, and verifies.
7. UI updates only from the verified result.

## Failure behavior

- Discovery, network, TLS trust/identity, authentication, capability, validation, quota, conflict, activation, and verification failures remain distinct.
- Any TLS or identity failure is terminal and has no bypass.
- A failed mutation never reports success without read-back verification.
- Secrets, SASL payloads, complete scripts, and server response bodies are absent from logs and user-facing technical details.
- Cancellation closes the active session and leaves UI state unknown until refreshed.

## Testing

- NIO embedded-channel and loopback tests for connect, fragmentation, STARTTLS pipeline insertion, coalesced plaintext `OK` plus first TLS record, TLS failure, pending-I/O release, cancellation, and exactly-once close.
- Synthetic trust/identity tests for DNS-ID, SRV-ID, SAN-only behavior, wildcard restrictions, malformed SANs, and no Common Name fallback.
- Discovery tests for priorities, weights, malformed records, no records, and manual fallback.
- Keychain tests behind an injected Security client; one opt-in integration test uses a temporary service name and deletes it.
- Repository transcript tests cover refresh, no-active state, byte preservation, validation failure, conflict before activation, successful activation/read-back, ambiguous interruption, rollback eligibility, and conservative retention.
- App-model tests cover setup, capability limitations, verified/unknown/conflict states, refresh, enable, disable, expiry validation, and redaction.
- Xcode UI smoke tests verify first-run and configured menu content without real credentials or network access.

## Delivery sequence

1. Live NIO STARTTLS transport and identity validation.
2. Discovery, account persistence, and Keychain boundaries.
3. Authenticated session factory and safe script repository.
4. Observable app model and setup UI.
5. Out-of-office refresh/mutation UI and lifecycle triggers.
6. Full fake-server, package, Xcode, and opt-in live interoperability verification.

## Security constraints

- Never read the home `.env` without separate explicit authorization.
- Never authenticate before successful TLS trust and identity validation.
- Never trust pre-TLS capabilities.
- Never expose a trust bypass.
- Never log credentials, authentication payloads, raw scripts, or unbounded server text.
- Never overwrite user-owned script bytes or user-named script objects in place.
