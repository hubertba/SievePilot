# SievePilot

A native open-source macOS menu-bar application for managing server-side Sieve email automation.

The first planned feature is an out-of-office rule with reliable server-side expiry. Future features may include server-side folder sorting.

## Status

The initial release is feature complete: account setup, a secure ManageSieve client, safe versioned script updates, and an operational out-of-office menu are implemented. See [the design](docs/superpowers/specs/2026-04-24-sievepilot-design.md), [the core-engine plan](docs/superpowers/plans/2026-11-08-sievepilot-core-engine.md), and [the app-target design](docs/superpowers/specs/2026-11-09-macos-app-target-design.md).

Automated tests use deterministic fake transports and fake services. Live interoperability with a real ManageSieve server requires server access that you supply; it is not exercised by the automated test suite and is not claimed here.

## Using SievePilot

SievePilot lives in the menu bar (macOS 13 or newer) and manages one account.

### Setup

1. Choose the menu-bar icon and enter your email address, username, and password.
2. Leave automatic discovery on to find the ManageSieve server through DNS (`_sieve._tcp`), or turn it off and enter a host and port.
3. Choose **Test & Save**. SievePilot connects, upgrades the connection with `STARTTLS`, validates the server certificate chain and service identity, and only then authenticates. Nothing is saved unless that whole sequence succeeds. There is no option to bypass certificate trust, and capabilities advertised before TLS are never trusted.

Open **Settings** in the menu to edit the account (re-enter the password to re-verify it) or delete it.

### Keychain and privacy

- The password is stored only in your macOS Keychain. Non-secret settings (email address, username, server) are stored in Application Support.
- Passwords, authentication payloads, and script contents are kept out of error messages and logs.
- Apart from DNS lookups for server discovery, SievePilot talks only to your mail server. It has no analytics.

### Out of office

Enter an optional subject, a message, and the time the out-of-office should turn off, then choose **Save and Activate**. A message and a future expiry are required. A blank subject omits the Sieve `:subject` argument, so the server's default applies. The expiry is chosen in a named time zone: SievePilot rejects local times that do not exist because of a daylight-saving change, and for local times that occur twice it asks you to confirm the UTC offset. Expiry is enforced by the server, using a `currentdate` test inside the script, so it applies even while your Mac is off.

Before the first activation SievePilot explains that the vacation action runs before your existing executable rules. A later `stop` cannot disable it, but custom spam, discard, redirect, or other guard rules may no longer suppress the vacation response.

The displayed state always comes from a verified read of the server, never from the last action you requested. It is refreshed at launch, whenever the menu opens, after the Mac wakes or the network reconnects, and on demand with **Refresh**. After a wake or network change the state shows as unknown until it is verified again.

| Label | Meaning |
| --- | --- |
| Verified On | The active script has a SievePilot out-of-office rule that has not expired. |
| Verified Off | The server has no active script, or the active script has no SievePilot out-of-office rule. |
| Expiry passed — script verified; server clock applies | The verified script still contains an expired rule; the server's clock decides. It is removed on the next save. |
| Unknown — verification required | The state is stale, a request timed out, or an activation could not be confirmed. Nothing is assumed. |
| Conflict — active script changed elsewhere | The active script changed while SievePilot was preparing its update. The update was not activated. |

Connection, validation, conflict, and activation errors stay visible until you acknowledge them or a later refresh resolves them.

### Supported servers and capabilities

SievePilot requires an authoritative post-TLS ManageSieve capability list that includes the Sieve extensions `vacation`, `date`, and `relational`.

- Without `vacation`, out of office is unavailable.
- Without both `date` and `relational`, scheduled expiry is unavailable. SievePilot offers no local fallback because an expiry that depends on your Mac being awake would be unreliable.
- The menu names the missing extensions instead of showing unexplained disabled controls. When a server lacks any required extension, SievePilot refuses to read or change the script, reports exactly which extensions are missing, and never guesses a verified state.

### Safe script versions and backups

SievePilot never edits your script in place. It treats the active script as raw bytes, changes only the clearly marked sections it owns, uploads the result as a new, randomly named script version, activates that version, and reads it back to confirm it is byte-identical. Your own rules are preserved. If the active script changed after SievePilot read it, the update is reported as a conflict and is not activated.

Every earlier version stays on the server as a rollback copy. SievePilot does not currently prune old versions or offer a restore command, so you can switch back with your mail provider's Sieve tools. ManageSieve has no atomic compare-and-set, so a narrow race remains if another client activates a script at the same moment; avoid editing the same account from several clients at once. Keep independent backups of important Sieve scripts.

## Development

Open the native macOS project in Xcode:

```bash
open SievePilot.xcodeproj
```

Run the core package tests:

```bash
swift test
```

With full Xcode installed, build the app and run its tests:

```bash
xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'
```
