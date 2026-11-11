# Live ManageSieve interoperability

SievePilot's automated suite uses deterministic fake and loopback transports. The tests in
`Tests/SievePilotCoreTests/Live/LiveManageSieveInteropTests.swift` exercise a real ManageSieve server instead.
They are **opt-in**: by default `swift test` skips them and still passes. This repository does not claim that
any live run has been performed against a particular server.

## Rules

- Variables are read **only from the process environment**. The tests never load a `.env` file or any other
  credentials file. If you keep settings in a file, export them in your shell yourself.
- Never commit, paste, or log the password. The tests keep passwords, authentication payloads, script bodies,
  and raw server text out of assertion messages.
- The tests never offer a way to skip certificate trust or identity validation. Authentication happens only after
  STARTTLS, certificate-chain validation, and service-identity validation succeed.
- Use only a server and account you are authorized to test.

## Variables

Required for both tests:

| Variable | Meaning |
| --- | --- |
| `SIEVEPILOT_LIVE_INTEROP` | Must be `1` to enable any live test. |
| `SIEVEPILOT_LIVE_EMAIL` | Email address of the test account. |
| `SIEVEPILOT_LIVE_USERNAME` | ManageSieve login name. |
| `SIEVEPILOT_LIVE_PASSWORD` | Account password (process environment only). |

Choose exactly one way to locate the server:

| Variable | Meaning |
| --- | --- |
| `SIEVEPILOT_LIVE_SOURCE_DOMAIN` | Automatic discovery through DNS (`_sieve._tcp`). Must equal the domain of `SIEVEPILOT_LIVE_EMAIL`. Set it **alone**. The reference identities come from discovery. |
| `SIEVEPILOT_LIVE_HOST` and `SIEVEPILOT_LIVE_PORT` | Manual endpoint. Set both. The certificate must be valid for exactly that host name. The tests add no other identity. |

Required only for the destructive test, in addition to the above:

| Variable | Meaning |
| --- | --- |
| `SIEVEPILOT_LIVE_DESTRUCTIVE` | Must be `1`. |
| `SIEVEPILOT_LIVE_DEDICATED_ACCOUNT_ACK` | Must be exactly `dedicated-account-backed-up`, confirming the account is dedicated to testing and its scripts are backed up. |

If you opt in with a missing or conflicting variable, the test fails and names the variable (never its value).

## Tests

- `testConnectsSecurelyAuthenticatesAndReadsCapabilities` (non-destructive): connects, upgrades with STARTTLS,
  validates trust and identity, authenticates, checks that the post-TLS capability list is authoritative, advertises
  `SASL` and `SIEVE`, and includes the `vacation`, `date`, and `relational` Sieve extensions, then logs out and
  opens a second session. It sends no `PUTSCRIPT`, `SETACTIVE`, or `DELETESCRIPT`.
- `testDestructiveScriptRoundTripActivationRollbackAndCleanup` (destructive): see below.

## Dedicated account and backup warning

The destructive test uploads, activates, and deletes scripts. Run it **only against a dedicated test account**
that holds no mail you care about. While a test script is active the server may send real vacation replies to mail
that arrives on that account. Before running it, **back up all Sieve scripts** with your provider's tools and
note which script is active. SievePilot's own cleanup is a safety net, not a substitute for a backup.

## What the destructive test does and how it cleans up

1. Records the script names, the active script name, and the active script's exact bytes.
2. Uploads an inactive script with multi-byte UTF-8 and mixed `CRLF`/`LF` line endings and no trailing newline,
   reads it back, and requires the bytes to be identical, the script to be inactive, and the delete to succeed.
3. Enables an out-of-office rule through `SieveAccountService`: a new, randomly named script is uploaded, activated,
   and read back byte-identically. It then disables the rule the same way, which creates a second new version.
4. Rolls back: re-activates the original active script (or deactivates all scripts if there was none).
5. Deletes only the script names created by this run. Those names start with `sievepilot-<random UUID>-` or
   `sievepilot-interop-<random UUID>-`, where the UUID is generated for each run. Names that existed before the test are never deleted
   or overwritten.
6. Verifies that the script names, the active script, and the active script's bytes match the initial state.

Rollback and cleanup run even if an earlier step fails. If cleanup itself fails, the test reports it; inspect the account
for names starting with `sievepilot-` and restore from your backup if needed.

## Expected server capabilities

After authentication the server should advertise a post-TLS capability list with `IMPLEMENTATION`, `VERSION`, `SASL`
(`PLAIN` or `LOGIN`), and `SIEVE` including `vacation`, `date`, and `relational`. `CHECKSCRIPT` is used when advertised.
The server must support `STARTTLS` on the ManageSieve port.

## Running

Export the variables in your shell, then run only the live tests:

```bash
. "$HOME/.swiftly/env.sh"
export SIEVEPILOT_LIVE_INTEROP=1
# ... export the other variables from the tables above ...
swift test --filter LiveManageSieveInteropTests
```
