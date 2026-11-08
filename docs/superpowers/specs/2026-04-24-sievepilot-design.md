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

- overwrites, reformats, truncates, or silently changes an existing rule;
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

### 1. Server-side expiry in a managed block — selected

SievePilot inserts one clearly delimited block into a copy of the active script. The block uses `currentdate` and an absolute UTC expiry, so the mail server stops generating vacation replies at the selected time. Everything outside the managed block is copied byte-for-byte.

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
6. SievePilot connects with TLS, validates the certificate, authenticates, reads capabilities, and reports whether timed out-of-office rules are supported.
7. On success, connection settings and the Keychain credential reference are saved.

### Main popover

```text
SievePilot

Account: user@example.com                 [Settings]
Server:  mail.example.com                 Connected

Out of Office                         [ Off / On ]
Subject:  [Out of office                         ]
Message:  [                                      ]
          [                                      ]
          [                                      ]

Turn off: [24 Apr 2026] [17:00] [Europe/Warsaw]

                              [Save and Activate]

Last server update: 24 Apr 2026, 10:42
```

- Enabling requires a non-empty message and a future expiry.
- The user chooses the expiry in a named local time zone. SievePilot converts it to UTC in the generated script and stores the original zone for display.
- Disabling immediately uploads and activates a new script version with the managed block removed.
- When the expiry has passed, the UI shows the feature as off even if the harmless expired block remains on the server. On the next successful save, SievePilot removes the expired block.
- Connection, validation, and activation errors remain visible until acknowledged or resolved.

### Capability limitations

- Without `vacation`, the out-of-office feature is unavailable.
- Without both `date` and `relational`, scheduled expiry is unavailable and v1 does not offer an unreliable local fallback.
- The UI shows the missing server capabilities rather than presenting disabled controls without explanation.

## Managed script format

SievePilot owns only text between versioned markers with an identifier unlikely to collide with user comments:

```sieve
# BEGIN SIEVEPILOT MANAGED BLOCK v1: out-of-office
require ["vacation", "date", "relational"];

if currentdate :zone "+0000" :value "lt" "iso8601" "2026-04-24T15:00:00Z" {
    vacation
        :subject "Out of office"
        "I will reply when I return.";
}
# END SIEVEPILOT MANAGED BLOCK v1: out-of-office
```

The exact generated syntax must be confirmed against RFC 5260 and at least Dovecot Pigeonhole and one independent Sieve implementation during development.

Rules for modifying scripts:

- If no managed block exists, prepend one to the active script, separated by a blank line.
- If one valid managed block exists, replace or remove exactly that range.
- If markers are malformed, nested, duplicated, or version-unknown, refuse to modify the script and explain the conflict.
- Never parse and regenerate text outside the managed block.
- Preserve the original script's bytes outside that range, including comments, whitespace, line endings, and unknown extensions.
- Escape all generated Sieve string values according to the language specification; user text is never interpolated as raw source.
- The generated block executes before the user's existing rules so a later `stop` command cannot prevent the vacation action from being evaluated.

Future features receive separate named managed blocks. They must not share one generated monolith; this keeps each feature independently replaceable and makes conflicts visible.

## Safe server update protocol

For each change:

1. Connect using TLS and authenticate.
2. read capabilities and reject unsupported requested behavior;
3. use `LISTSCRIPTS` to identify the active script;
4. use `GETSCRIPT` to retrieve it, or start from an empty script if none is active;
5. patch only the SievePilot-owned block in memory;
6. validate the complete candidate with `CHECKSCRIPT` when supported;
7. upload it under a new SievePilot-owned, timestamped version name with `PUTSCRIPT`;
8. activate that version using `SETACTIVE`;
9. read back the active script name and contents to verify success;
10. retain the previously active script as rollback material.

SievePilot never overwrites a user-named script in place. It may prune old scripts only when their names and embedded metadata prove they were created by SievePilot. The initial retention policy is the five most recent SievePilot versions. If server quota prevents creating a safe new version, the operation fails without altering the active script.

If `CHECKSCRIPT` is unavailable, SievePilot may rely on `PUTSCRIPT` server validation only if the server rejects invalid scripts without replacing or activating the existing script. This behavior must be covered by interoperability tests; otherwise the app refuses modification on that server.

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

- SRV discovery;
- TLS connection and trust evaluation;
- greeting and capability parsing;
- SASL PLAIN and LOGIN authentication;
- literal and quoted-string framing;
- `LISTSCRIPTS`, `GETSCRIPT`, `CHECKSCRIPT`, `PUTSCRIPT`, `SETACTIVE`, and `LOGOUT`;
- explicit command timeouts and cancellation;
- redacted structured logging that never records passwords or complete script bodies.

The protocol engine is independent of SwiftUI and exposed behind an interface suitable for deterministic fake-server tests.

### Rule engine

Feature modules produce and own distinct managed blocks. The initial `OutOfOfficeRule` module:

- validates the form model;
- converts the chosen expiry to UTC;
- generates escaped Sieve source;
- detects, inserts, replaces, and removes its managed block;
- derives whether a retrieved block is enabled, expired, malformed, or unknown-version.

A coordinator combines requested feature changes with the untouched active script and performs the safe server update protocol.

## Error handling

Errors are classified into discovery, TLS trust, authentication, capability, network, script conflict, script validation, quota, activation, and verification failures. User-facing messages state what did not change. Technical details are available through a copyable diagnostics view with secrets and script contents redacted.

No failure before verified activation changes the app's displayed server state to enabled. After an ambiguous network interruption, SievePilot reconnects and reads the active script before reporting success or failure.

## Security and privacy

- Require authenticated TLS for all authentication and script operations.
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

- Unit tests for ManageSieve tokenization, literals, response parsing, capability parsing, and command state transitions.
- Unit tests for Sieve string escaping and marker insertion, replacement, removal, malformed markers, line-ending preservation, and byte-for-byte preservation outside managed blocks.
- Time-zone and daylight-saving tests for expiry conversion.
- Transcript-driven fake-server tests for success, authentication failure, invalid scripts, quota errors, dropped connections, and ambiguous activation results.
- Integration tests against containerized Dovecot Pigeonhole.
- Interoperability tests against at least one non-Dovecot ManageSieve implementation before claiming general compatibility.
- UI tests for setup, capability limitations, enabling, disabling, expiry display, and error recovery.
- A destructive-test account verifies that arbitrary representative scripts remain semantically and textually unchanged outside SievePilot blocks.

## Future features

Folder sorting will be designed as a separate feature after the initial out-of-office release. It can add its own managed block and UI while reusing account discovery, credentials, ManageSieve transport, safe versioned updates, validation, and diagnostics. Its behavior and interaction with user-authored ordering must go through a separate design because Sieve rule ordering can change message delivery semantics.

## Decisions left to the builder

- Internal type names and source-file organization.
- Whether the TLS stream is built directly on Network.framework or a small well-maintained Swift package, provided the dependency and security implications are documented.
- Exact visual styling that follows standard macOS controls and accessibility conventions.
- The fake-server test harness implementation.
- Timestamped server script naming details within ManageSieve limits.

## Decisions still requiring owner confirmation

- Open-source license.
- Whether Apple Developer Program credentials are available for signed and notarized GitHub releases.
