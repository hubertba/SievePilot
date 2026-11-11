# TEST ONLY TLS fixtures

**These private keys are public test fixtures. NEVER use them for real services,
credentials, or deployed trust anchors.** The fixture CA is never installed into
system trust. Production tests verify it is rejected by macOS system trust.

Run `python3 Tests/SievePilotCoreTests/Fixtures/TLS/regenerate.py` from the repository
root to regenerate the PEM/DER certificates using the fixed fixture RSA keys,
serials, subjects and 2020–2040 validity dates. RSA/SHA256 signatures make the
output deterministic. Set `OPENSSL` to choose an OpenSSL-compatible executable.
Keys intentionally remain fixed; generating new keys changes all certificates.

The server's CN is `target.example.net` (must not authenticate that target).
Its SANs identify `source.example.org` and `_sieve.source.example.org` only.
Tests inject Swift Certificates RFC5280 trust anchored at this fixture CA at a
fixed time; production always uses Security.framework system trust.
