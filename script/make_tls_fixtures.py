#!/usr/bin/env python3
"""Generate disposable test-only CA and FTPS certificates (never production trust)."""
from pathlib import Path
import subprocess
import sys
root=Path(sys.argv[1]).resolve();root.mkdir(parents=True,exist_ok=True)
def run(*args):
    subprocess.run(['openssl',*args],cwd=root,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
run('req','-x509','-newkey','rsa:2048','-nodes','-keyout','ca.key','-out','ca.pem','-days','3650','-subj','/CN=Disposable FTP Test CA')
(root/'index').write_text('');(root/'index.attr').write_text('unique_subject = no\n');(root/'serial').write_text('1000\n')
(root/'ca.cnf').write_text('''[ca]
default_ca = test
[test]
database = index
serial = serial
new_certs_dir = .
certificate = ca.pem
private_key = ca.key
default_md = sha256
policy = policy
[policy]
commonName = supplied
[good]
subjectAltName = DNS:localhost,IP:127.0.0.1
[wrong]
subjectAltName = DNS:wrong.example
''')
for name in ('good','wrong','expired'):
    run('req','-new','-newkey','rsa:2048','-nodes','-keyout',name+'.key','-out',name+'.csr','-subj','/CN=localhost')
    dates=['-startdate','20200101000000Z','-enddate','20210101000000Z'] if name=='expired' else ['-days','3650']
    run('ca','-batch','-config','ca.cnf','-extensions','wrong' if name=='wrong' else 'good','-in',name+'.csr','-out',name+'.pem',*dates)
run('req','-x509','-newkey','rsa:2048','-nodes','-keyout','self.key','-out','self.pem','-days','3650','-subj','/CN=localhost')
print(root)
