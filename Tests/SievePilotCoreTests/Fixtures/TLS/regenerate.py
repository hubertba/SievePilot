#!/usr/bin/env python3
"""TEST ONLY: checked-in private keys are public fixtures, NEVER deploy them.
Regenerate byte-identical RSA/SHA256 certificates using the fixed fixture keys,
serials and validity dates. Requires OpenSSL; does not touch system trust.
"""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
OPENSSL = os.environ.get('OPENSSL', 'openssl')

def run(*args):
    subprocess.run([OPENSSL, *map(str, args)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'index').write_text('')
    (tmp / 'serial').write_text('1000\n')
    config = tmp / 'ca.cnf'
    config.write_text(f'''[ca]
default_ca = fixture
[fixture]
database = {tmp}/index
serial = {tmp}/serial
new_certs_dir = {tmp}
private_key = {HERE}/ca-key.pem
certificate = {HERE}/ca.pem
default_md = sha256
policy = names
unique_subject = no
[names]
commonName = supplied
[root]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:source.example.org,otherName:1.3.6.1.5.5.7.8.7;IA5:_sieve.source.example.org
''')
    for name, cn, extension in [('ca', 'SievePilot TEST ONLY CA', 'root'), ('server', 'target.example.net', 'server')]:
        csr = tmp / f'{name}.csr'
        run('req', '-new', '-key', HERE / f'{name}-key.pem', '-subj', f'/CN={cn}', '-out', csr)
        args = ['ca', '-batch', '-notext', '-config', config, '-extensions', extension,
                '-startdate', '20200101000000Z', '-enddate', '20400101000000Z', '-in', csr, '-out', HERE / f'{name}.pem']
        if name == 'ca':
            args += ['-selfsign', '-keyfile', HERE / 'ca-key.pem']
        run(*args)
        run('x509', '-in', HERE / f'{name}.pem', '-outform', 'DER', '-out', HERE / f'{name}.der')
