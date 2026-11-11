# SievePilot Design

**Date:** 2026-04-24  
**Status:** Draft for approval  
**Initial release:** Native macOS menu-bar application

## Intent and why

SievePilot is an open-source macOS application that makes server-side email automation accessible without requiring users to edit Sieve source manually. Its first feature is an out-of-office rule that can turn itself off at a chosen date and time even when the Mac is asleep or SievePilot is not running.

The product name and architecture deliberately allow later independent features, such as server-side folder sorting. Those features are not part of the initial release.

## Goals

- Provide a native menu-bar experience for configuring and toggling an out-of-office response.
- Connect to standards-compatible ManageSieve servers over TLS.
- Discover a server through an email domain's `_sieve._tcp` SRV record, with manual configuration available.
- Store credentials in macOS Keychain.
- Preserve arbitrary existing Sieve scripts without reformatting or semantically rewriting user-owned rules.
- Enforce scheduled expiry on the mail server using Sieve's `date` and `relational` extensions.
- Validate every generated script before activation.
- Make changes recoverable and leave prior server-side script versions available as backups.
- Be suitable for an open-source GitHub repository and reproducible source builds.
- Keep the internal rule-management architecture extensible for future features.

## Non-goals for the initial release

- Folder-sorting rule creation or editing.
- A general-purpose visual editor for all Sieve language constructs.
- Editing or formatting user-owned Sieve code.
- Importing Apple Mail rules.
- OAuth or provider-specific web authentication.
- iOS support.
- App Store distribution.
- Automatic application updates.
- A local scheduler or always-running background helper.
- Supporting scheduled expiry on servers without `date` and `relational` capabilities.

## Anti-goals

The release is a failure if it:

- overwrites a user-named script object in place, or reformats, truncates, or changes any user-owned script bytes while producing a SievePilot version;
- depends on the Mac being awake at the expiry time;
- sends credentials without authenticated TLS;
- activates an invalid script;
- hides a server-side failure behind an apparently successful UI state;
- claims broad Sieve compatibility while relying on Dovecot-specific behavior.

## Constraints and assumptions

- The first implementation targets macOS 13 or newer so it can use SwiftUI `MenuBarExtra`.
- The application is implemented in Swift using SwiftUI, AppKit where necessary, Network.framework or a small purpose-built TLS socket layer, and Security.framework for Keychain access.
- No Perl runtime or `sieve-connect` executable is bundled. `sieve-connect` may be used during development as an interoperability reference.
- TLS certificate validation uses the system trust store. Plaintext ManageSieve authentication is never permitted.
- Initial authentication support is SASL `PLAIN` and `LOGIN` inside TLS. The username is editable because it may differ from the email address.
- The reference server, `mail.chilicode.com:4190`, advertises Dovecot Pigeonhole, `vacation`, `date`, `relational`, and SASL `PLAIN LOGIN` over TLS.
- Public signed and notarized binaries require Apple Developer Program credentials. The repository must not contain signing secrets.

## Approaches considered

### 1. Server-side expiry in grammar-safe managed sections — selected

SievePilot inserts separately marked requirement and executable sections into a copy of the active script. A byte-oriented preamble scanner places them after existing `require` commands and before user executable commands. The rule uses `currentdate` and an absolute UTC expiry, so the mail server stops generating vacation replies at the selected time. Everything outside inserted or replaced byte ranges is preserved byte-for-byte.

This is reliable while the Mac is asleep and does not require a background process. It requires the server to advertise `vacation`, `date`, and `relational` for timed out-of-office rules.

### 2. Local scheduled disable

A launch agent or login item reconnects at the expiry time and removes the rule. This works with more limited Sieve servers but can run late when the Mac is asleep, off, or offline. It conflicts with the reliability goal and was rejected.

### 3. Hybrid server-side and local scheduling

Use server-side expiry when available and a local scheduler otherwise. This broadens compatibility but substantially increases lifecycle, permissions, and failure-state complexity. It was rejected for the initial release; it may be reconsidered later.

## User experience

### First-run setup

1. The menu-bar item opens a compact popover.
2. The user enters an email address.
3. SievePilot queries `_sieve._tcp.<email-domain>`.
4. If discovery succeeds, it fills the host and port. If not, the user can enter them manually.
5. The user confirms or edits the authentication username and enters a password.
6. SievePilot opens a ManageSieve connection, upgrades it with `STARTTLS`, validates the certificate against the configured service identity, discards all pre-TLS capabilities, reacquires capabilities over TLS, authenticates, and reports whether timed out-of-office rules are supported.
7. On success, connection settings and the Keychain credential reference are saved. Implicit TLS is available only as an explicit manual setting; it is never an automatic fallback from failed `STARTTLS`.

### Main popover

```text
SievePilot

Account: user@example.com                 [Settings]
Server:  mail.example.com                 Verified 10:42

Out of Office                  [ Verified Off / On ]
Subject:  [Out of office                         ]
Message:  [                                      ]
          [                                      ]
          [                                      ]

Turn off: [24 Apr 2026] [17:00] [Europe/Warsaw]

                              [Save and Activate]

Last server update: 24 Apr 2026, 10:42
```

- Enabling requires a non-empty message and a future expiry. A blank subject omits the Sieve `:subject` argument so the server's standard default applies.
- The user chooses the expiry in a named local time zone. SievePilot rejects nonexistent daylight-saving times. For a repeated local time, it displays and requires confirmation of the chosen UTC offset. It persists the resolved instant, time-zone identifier, and chosen offset.
- Disabling uploads and activates a new script version with both SievePilot out-of-office sections removed.
- `Verified Off` means the server was refreshed and either has no active script or has an active script whose out-of-office requirements and rule sections are absent. When the local clock has passed an expiry still present in the verified script, the UI instead shows `Expiry passed — script verified; server clock applies`. On the next successful save, SievePilot removes the expired sections.
- Server state is refreshed when the account loads, the popover opens, the Mac wakes or reconnects, and immediately before every mutation. A manual Refresh action is also available.
- The displayed state is `Verified On`, `Verified Off`, `Expiry passed — script verified; server clock applies`, `Unknown — verification required`, or `Conflict — active script changed elsewhere`; it is never inferred from the last requested operation.
- Connection, validation, conflict, and activation errors remain visible until acknowledged or resolved.
- Before first activation, the app explains that the vacation action runs before existing executable rules. This prevents later `stop` commands from disabling it, but custom spam, discard, redirect, or other guard rules may no longer suppress the vacation response.

### Capability limitations

- Without `vacation`, the out-of-office feature is unavailable.
- Without both `date` and `relational`, scheduled expiry is unavailable and v1 does not offer an unreliable local fallback.
- The UI shows the missing server capabilities rather than presenting disabled controls without explanation.

## Managed script format

SievePilot treats every fetched script as raw `Data`. Untouched bytes are never decoded and re-encoded as a complete Swift `String`. A small byte-oriented lexer recognizes only the grammar needed to find a legal insertion boundary: an optional UTF-8 BOM, whitespace, comments, quoted and multiline strings, leading `require` commands, and the first executable command.

Sieve requires every `require` command to precede every non-`require` command. SievePilot therefore owns an always-present metadata comment section plus independently marked requirements and rule sections. They are inserted after all existing leading `require` commands and before the first user executable command:

```sieve
require ["fileinto"];

# BEGIN SIEVEPILOT METADATA v1
# account-id: 8cbcbcc8-2e3c-49be-9464-a238ad398005
# version-id: d69d1f7d-7178-4a97-a801-eae36bb7e05e
# predecessor-sha256: 8c675...
# END SIEVEPILOT METADATA v1

# BEGIN SIEVEPILOT REQUIREMENTS v1
require ["vacation", "date", "relational"];
# END SIEVEPILOT REQUIREMENTS v1

# BEGIN SIEVEPILOT RULE v1: out-of-office
if currentdate :zone "+0000" :value "lt" "iso8601" "2026-04-24T15:00:00Z" {
    vacation
        :addresses ["user@example.com"]
        :handle "sievepilot-out-of-office-8cbcbcc8-2e3c-49be-9464-a238ad398005"
        :subject "Out of office"
        "I will reply when I return.";
}
# END SIEVEPILOT RULE v1: out-of-office

# Original executable commands continue byte-for-byte here.
```

RFC 5260 defines `iso8601` as restricted RFC 3339 and requires a zero offset to be represented by uppercase `Z`. With `:zone "+0000"`, both operands use canonical UTC. The `:value "lt"` comparison means the vacation action runs strictly before the expiry instant and stops at equality. This exact expression must pass before/at/after boundary interoperability tests against Dovecot Pigeonhole and one independent Sieve implementation before release.

Rules for modifying scripts:

- If no managed sections exist, insert metadata, requirements, and rule sections at the grammar-safe boundary after all leading `require` commands and before the first executable command.
- Every SievePilot-owned version, including a disabled version, retains exactly one metadata section. Disabling removes the out-of-office requirements and rule sections but replaces the metadata with a new version record.
- If one valid section of each expected kind exists, replace or remove exactly those byte ranges.
- If markers are malformed, nested, duplicated, misplaced, or version-unknown, refuse to modify the script and explain the conflict.
- If the leading preamble cannot be lexed safely, refuse modification rather than guessing.
- Never parse and regenerate bytes outside SievePilot-owned sections.
- Preserve all original bytes outside inserted or removed ranges, including a BOM, comments, invalid UTF-8, whitespace, mixed line endings, non-ASCII literals, and unknown extensions.
- Escape generated Sieve string values according to the language specification; user text is never interpolated as raw source.
- Emit `:addresses` with the configured account email address. V1 has no alias editor; unlisted aliases may follow server-specific recipient detection behavior.
- Omit `:subject` when the configured subject is blank.
- Emit a stable per-account out-of-office `:handle` so content edits retain the same vacation-response identity where the server preserves tracking across script changes. RFC 5230 permits servers to reset tracking when a script changes, so the UI and documentation do not promise otherwise.
- Omit `:days` and `:seconds` in v1, deliberately using the server's standard repeat interval; document that the interval can differ by server.
- The generated rule executes before user executable rules so a later `stop` cannot suppress it. The UI discloses that this may also bypass custom spam and other guard rules.

Future features receive separate named rule sections. Shared requirements may use the versioned requirements section, but independently replaceable feature rules must not be combined into one generated monolith.

## ManageSieve transport state machine

The standard port-4190 flow follows RFC 5804:

1. Connect over TCP and receive a bounded unauthenticated greeting.
2. Require the `STARTTLS` capability and issue `STARTTLS`; do not authenticate or trust pre-TLS SASL or Sieve capabilities.
3. Establish TLS using the system trust store and fail closed on any trust or identity error. There is no trust-bypass control.
4. Discard the pre-TLS capability set and read the capability response the server re-issues, unsolicited, over TLS (RFC 5804 §2.2). Do not issue `CAPABILITY` before that response is consumed.
5. Select only a configured SASL mechanism advertised after TLS, authenticate, and consume the authenticated capability response.
6. Perform script operations only in the authenticated state.

For SRV discovery, the reference identifiers are derived from the user-entered source domain before DNS lookup, following RFC 9525: `_sieve.<source-domain>` as an SRV-ID and the source domain as a DNS-ID. Matching uses certificate `subjectAltName` entries only, follows current DNS wildcard rules, and never falls back to the legacy Common Name. An unauthenticated SRV target is not added as a trusted identity. A manually configured host is an explicit user-selected DNS-ID. Supporting an alternative hosting name requires explicit user configuration; failed certificate checks never fall back to accepting the discovered target. Explicit implicit-TLS mode validates the same reference identifiers.

## Safe server update and concurrency protocol

For each change:

1. Establish authenticated TLS and reject unsupported requested behavior from post-TLS capabilities.
2. Use `LISTSCRIPTS` and `GETSCRIPT` to record the baseline active script name, raw bytes, and SHA-256 digest, or an explicit no-active-script state.
3. Patch only SievePilot-owned byte ranges in memory.
4. Validate the complete candidate with `CHECKSCRIPT` when supported.
5. Generate a version name containing at least 128 bits from a cryptographically secure random source. Repeat `LISTSCRIPTS` and regenerate if that exact name already exists, then upload with `PUTSCRIPT`. ManageSieve has no atomic create-only operation, so the design treats the remaining check-to-`PUTSCRIPT` collision race as negligible but not impossible.
6. Immediately repeat `LISTSCRIPTS` and `GETSCRIPT`. If the active name, bytes, or digest differs from the baseline, delete the unused candidate when safe and report a conflict without activating it.
7. Activate the candidate using `SETACTIVE`.
8. Read back the active name and bytes. Success requires the candidate to be active and byte-identical.
9. Retain the baseline script as rollback material and update the local ownership manifest.

ManageSieve has no atomic compare-and-set or locking operation, so updates provide best-effort optimistic concurrency rather than a zero-loss guarantee. Another client can activate a script after step 6 and have that activation displaced by step 7 without SievePilot being able to detect the intermediate state. The setup documentation and diagnostics disclose this limitation and advise against simultaneous editing from multiple clients. Detected conflicts never activate stale content, but the narrow final race is an accepted protocol limitation of v1. A post-activation interruption produces `Unknown — verification required`, never assumed success or failure. On reconnection:

- candidate active and byte-identical means success;
- a baseline active script that remains byte-identical, or a baseline no-active state that still has no active script, means the operation did not apply;
- any unrelated active script or unexpected bytes means conflict.

Automatic rollback is allowed only when the candidate is still active and the intended baseline is still byte-identical. SievePilot never automatically overwrites an unrelated active script.

SievePilot never deliberately overwrites a user-named script in place. Each account receives a random stable ownership identifier stored in the local versioned account model. Version names and the independently marked metadata section include that identifier and a unique version identifier using generated, ASCII-safe values.

The local manifest records:

- the initial baseline script name and SHA-256 digest, or an explicit no-active-script state;
- ordered owned versions with name, digest, version identifier, predecessor name and digest, creation time, and enabled or disabled feature state;
- the latest server verification time and outcome.

Pruning requires agreement between manifest data and the embedded metadata section. After manifest loss, unknown scripts are retained conservatively. Retention counts only owned versions; the active script and initial pre-SievePilot baseline are never pruned automatically.

Restore Previous Version is itself a best-effort concurrency-checked activation: refresh and record the current active name and digest, fetch the selected target and require its manifest digest to match, immediately confirm the current active script is unchanged, issue `SETACTIVE` for the target or `SETACTIVE ""` for the recorded no-active baseline, then read back and verify. A missing or modified target, changed current script, or ambiguous result stops restoration and reports conflict or unknown state. The same unavoidable final `SETACTIVE` race is disclosed.

If server quota prevents creating a safe new version, the operation fails without altering the active script. If `CHECKSCRIPT` is unavailable, SievePilot may rely on `PUTSCRIPT` validation only when interoperability tests prove that the server rejects invalid scripts without replacing or activating the existing script; otherwise modification is refused.

## Application architecture

### UI layer

- SwiftUI menu-bar scene and settings windows.
- Observable account and out-of-office view models.
- No networking or script generation directly in views.

### Account and credential layer

- Account configuration: email address, username, discovered/manual host and port, and TLS policy.
- Password stored as a generic-password Keychain item scoped to account and server.
- Non-secret settings stored using a versioned Codable model.
- Initial release supports one account in the UI, while storage and service interfaces use stable account identifiers so multi-account support can be added later.

### ManageSieve client

A focused protocol implementation with:

- SRV discovery with source-domain service identity;
- explicit plain TCP, `STARTTLS`, TLS-established, authenticated, and closed states;
- system trust and service-identity evaluation with no bypass;
- greeting and capability parsing, including mandatory capability replacement after TLS;
- SASL PLAIN and LOGIN authentication only inside authenticated TLS;
- literal and quoted-string framing;
- `CAPABILITY`, `STARTTLS`, `LISTSCRIPTS`, `GETSCRIPT`, `CHECKSCRIPT`, `PUTSCRIPT`, `SETACTIVE`, `DELETESCRIPT`, and `LOGOUT`;
- explicit command timeouts, response-size bounds, and cancellation;
- redacted structured logging that never records passwords or complete script bodies.

The protocol engine is independent of SwiftUI and exposed behind an interface suitable for deterministic fake-server tests.

### Rule engine

Feature modules produce and own distinct managed sections. The initial `OutOfOfficeRule` module:

- validates the form model and resolves daylight-saving gaps or repeated times explicitly;
- persists the resolved UTC instant, named zone, and selected offset;
- generates escaped Sieve source with a strict-exclusive expiry boundary;
- detects, inserts, replaces, and removes its requirements and rule sections using raw byte offsets;
- derives whether a retrieved section is enabled, expired, malformed, or unknown-version.

A byte-oriented preamble scanner locates legal insertion points without constructing an AST or reserializing user source. A coordinator combines requested feature changes with the untouched active bytes and performs the safe concurrency protocol.

## Error handling

Errors are classified into discovery, TLS trust or identity, authentication, capability, network, script conflict, script validation, quota, activation, rollback, and verification failures. User-facing messages distinguish verified unchanged state from unknown or conflicting state. Technical details include the active script name and last verification time but redact secrets and script contents.

No requested operation changes the displayed state until verification succeeds. After an ambiguous interruption, SievePilot displays `Unknown — verification required` and reconnects to classify the active script as candidate, baseline, or unrelated before reporting an outcome.

## Security and privacy

- Require authenticated TLS for all authentication and script operations; discard all pre-TLS capabilities and fail closed on certificate trust or service-identity errors.
- Derive SRV-discovered certificate reference identifiers from the configured source domain, not an unauthenticated SRV target.
- Use Keychain access restricted to the application.
- Do not collect telemetry in the initial release.
- Do not send scripts or credentials anywhere except the configured ManageSieve server.
- Redact SASL payloads, credentials, message bodies, and full scripts from logs.
- Treat server-provided strings and script sizes as untrusted input and enforce reasonable bounds.
- Document that a vacation response can reveal absence and that server-side suppression behavior is controlled by the mail server.

## Distribution and repository

- Repository name: `SievePilot`.
- License: a standard permissive open-source license, with the final choice left to the owner.
- Xcode project committed with no external dependency required for the core protocol implementation unless a reviewed library materially reduces protocol risk.
- GitHub Actions runs formatting checks, unit tests, and build verification on pull requests.
- Release automation supports Developer ID signing and Apple notarization using repository secrets supplied by the owner.
- If signing credentials are not available, source builds remain supported; the exact policy for publishing unsigned binaries must be decided before release work.
- Documentation includes supported server capabilities, setup instructions, privacy behavior, troubleshooting, and a warning that users should keep independent backups of important Sieve scripts.

## Testing strategy

- Unit tests for ManageSieve tokenization, literals, response parsing, capability parsing, and every transport state transition.
- STARTTLS downgrade, stale pre-TLS capability, certificate identity, authentication-before-TLS, size-bound, timeout, and cancellation tests.
- Unit and fuzz tests for the byte-oriented Sieve preamble scanner, including BOMs, comments, strings containing marker text, multiple `require` commands, invalid UTF-8, mixed line endings, empty scripts, and malformed input.
- Unit tests for Sieve escaping and section insertion, replacement, removal, malformed markers, and byte-for-byte preservation outside owned ranges.
- Before/at/after expiry boundary tests using canonical UTC `iso8601` values.
- Time-zone tests that reject nonexistent local times and disambiguate repeated local times.
- Transcript-driven fake-server tests for success, authentication failure, invalid scripts, quota errors, concurrent external edits, dropped connections at every update step, ambiguous activation, rollback failure, and manifest loss.
- Integration tests against containerized Dovecot Pigeonhole.
- Interoperability tests against at least one non-Dovecot ManageSieve implementation before claiming general compatibility.
- UI tests for setup, capability limitations, verified/unknown/conflict states, enabling, disabling, restoration, expiry display, and error recovery.
- Representative scripts containing early `stop`, spam guards, `discard`, `redirect`, and `fileinto` verify and document the selected early-execution semantics.
- Vacation tests cover stable-handle behavior across content edits and off/on cycles while allowing RFC 5230-compliant servers to reset tracking after script changes.
- A destructive-test account verifies that arbitrary representative scripts remain byte-identical outside SievePilot sections, detected conflicts do not activate stale content, and the unavoidable final activation race is represented accurately in diagnostics and documentation.

## Future features

Folder sorting will be designed as a separate feature after the initial out-of-office release. It can add its own managed rule section and UI while reusing account discovery, credentials, ManageSieve transport, safe versioned updates, validation, and diagnostics. Its behavior and interaction with user-authored ordering must go through a separate design because Sieve rule ordering can change message delivery semantics.

## Decisions left to the builder

- Internal type names and source-file organization.
- Whether the TLS stream is built directly on Network.framework or a small well-maintained Swift package, provided the dependency and security implications are documented.
- Exact visual styling that follows standard macOS controls and accessibility conventions.
- The fake-server test harness implementation.
- Timestamped server script naming details within ManageSieve limits.

## Decisions still requiring owner confirmation

- Open-source license.
- Whether Apple Developer Program credentials are available for signed and notarized GitHub releases.
