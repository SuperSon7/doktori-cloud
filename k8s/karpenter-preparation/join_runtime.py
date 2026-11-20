#!/usr/bin/env python3
"""Kubeadm worker join contract. Runtime mutations require --execute on Linux root.

Only the publisher runs on a fixed control-plane host. No reset/init, shell eval,
ASG call or secret-bearing stdout. AWS CLI credentials come from the host role.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import Request, ProxyHandler, build_opener


class ContractError(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise ContractError(reason)


def validate_config(c):
    require(re.fullmatch(r'[a-zA-Z0-9_-]{1,63}', c['cluster_name']), 'invalid cluster name')
    require(re.fullmatch(r'[a-z]{2}-[a-z]+-\d', c['region']), 'invalid AWS region')
    u = urlsplit(c['cluster_endpoint'])
    require(u.scheme == 'https' and u.hostname and u.port and u.path in ('', '/')
            and not u.username and not u.password and not u.query and not u.fragment,
            'endpoint must be https host:port')
    require(re.fullmatch(r'sha256:[a-f0-9]{64}', c['ca_spki_hash']), 'invalid CA pin')
    require(re.fullmatch(r'/[A-Za-z0-9_./-]+', c['join_config_parameter']), 'invalid parameter path')
    require(type(c['max_pods']) is int and 1 <= c['max_pods'] <= 110, 'invalid max_pods')
    return c


def validate_bundle(b, c, now):
    validate_config(c)
    require(set(b) == {'schema', 'cluster_name', 'endpoint', 'ca_spki_hash', 'token', 'issued_at', 'expires_at'}, 'unexpected join fields')
    require(b['schema'] == 1 and b['cluster_name'] == c['cluster_name'], 'cluster mismatch')
    require(b['endpoint'] == c['cluster_endpoint'], 'endpoint mismatch')
    require(b['ca_spki_hash'] == c['ca_spki_hash'], 'CA pin mismatch')
    require(re.fullmatch(r'[a-z0-9]{6}\.[a-z0-9]{16}', b['token']), 'invalid bootstrap token')
    require(type(b['issued_at']) is int and type(b['expires_at']) is int, 'invalid timestamps')
    require(b['issued_at'] <= now + 60 and b['issued_at'] >= now - 3600, 'invalid issuance time')
    require(300 <= b['expires_at'] - now <= 3600, 'insufficient token lifetime')
    require(0 < b['expires_at'] - b['issued_at'] <= 3600, 'excessive token lifetime')
    return b


def make_join(b, c, identity, now):
    validate_bundle(b, c, now)
    require(re.fullmatch(r'i-[a-f0-9]{8,17}', identity['id']), 'invalid instance id')
    require(re.fullmatch(re.escape(c['region']) + '[a-z]', identity['az']), 'unexpected availability zone')
    require(re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}', identity['name']), 'invalid private DNS name')
    return {
        'apiVersion': 'kubeadm.k8s.io/v1beta4', 'kind': 'JoinConfiguration',
        'discovery': {'bootstrapToken': {'apiServerEndpoint': urlsplit(b['endpoint']).netloc,
                                       'token': b['token'], 'caCertHashes': [b['ca_spki_hash']]}},
        'nodeRegistration': {'name': identity['name'], 'criSocket': 'unix:///run/containerd/containerd.sock',
            'taints': [{'key': 'karpenter.sh/unregistered', 'effect': 'NoExecute'},
                       {'key': 'doktori.io/canary', 'value': 'true', 'effect': 'NoSchedule'}],
            'kubeletExtraArgs': [{'name': 'provider-id', 'value': f"aws:///{identity['az']}/{identity['id']}"},
                                 {'name': 'max-pods', 'value': str(c['max_pods'])}]}}


def command(argv, stdin=None, timeout=60):
    # Keep kubeadm and AWS error output private: both may contain credentials.
    try:
        p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as e:
        raise ContractError(f'{argv[0]} unavailable or timed out') from e
    require(p.returncode == 0, f'{argv[0]} failed (exit {p.returncode}); inspect host locally without exporting secrets')
    return p.stdout


def aws(c, *args):
    return command(['aws', '--region', c['region'], '--no-cli-pager', *args])


def put_bundle(c, b):
    # Secret never appears in process argv, environment, Terraform state or userData.
    with tempfile.TemporaryDirectory(prefix='karpenter-publish-', dir='/run') as d:
        p = Path(d) / 'request.json'
        p.write_text(json.dumps({'Name': c['join_config_parameter'], 'Value': json.dumps(b),
                                'Type': 'SecureString', 'Tier': 'Standard', 'Overwrite': True,
                                'KeyId': c['kms_key_arn']}))
        p.chmod(0o600)
        aws(c, 'ssm', 'put-parameter', '--cli-input-json', 'file://' + str(p))


def publish(c):
    validate_config(c)
    require(re.fullmatch(r'arn:aws:kms:' + re.escape(c['region']) + r':\d{12}:key/[a-f0-9-]+', c['kms_key_arn']), 'use a dedicated KMS key ARN')
    # Verify the pinned cluster CA before issuing a token. Never derive trust from SSM.
    pub = command(['openssl', 'x509', '-pubkey', '-noout', '-in', '/etc/kubernetes/pki/ca.crt'])
    der = command(['openssl', 'pkey', '-pubin', '-outform', 'DER'], pub)
    require('sha256:' + hashlib.sha256(der).hexdigest() == c['ca_spki_hash'], 'publisher CA mismatch')
    issued = int(time.time())
    token = command(['kubeadm', 'token', 'create', '--ttl', '60m', '--kubeconfig', '/etc/kubernetes/admin.conf',
                     '--description', 'doktori-karpenter-worker']).decode().strip()
    # Advertise a shorter lifetime than kubeadm to leave a clock/processing margin.
    b = {'schema': 1, 'cluster_name': c['cluster_name'], 'endpoint': c['cluster_endpoint'],
         'ca_spki_hash': c['ca_spki_hash'], 'token': token, 'issued_at': issued, 'expires_at': issued + 3500}
    validate_bundle(b, c, int(time.time()))
    put_bundle(c, b)
    print('join bundle published; expires_at=' + datetime.fromtimestamp(b['expires_at'], timezone.utc).isoformat())


def imds_identity():
    opener = build_opener(ProxyHandler({}))
    base = 'http://169.254.169.254/latest/'
    token = opener.open(Request(base + 'api/token', method='PUT', headers={'X-aws-ec2-metadata-token-ttl-seconds':'60'}), timeout=5).read().decode()
    def read(path):
        return opener.open(Request(base + 'meta-data/' + path, headers={'X-aws-ec2-metadata-token':token}), timeout=5).read().decode().strip()
    return {'id':read('instance-id'), 'az':read('placement/availability-zone'), 'name':read('local-hostname')}


def join(c):
    validate_config(c)
    require(not Path('/etc/kubernetes/kubelet.conf').exists(), 'node already has kubelet.conf; refusing reset or rejoin')
    version = command(['kubeadm', 'version', '-o', 'short']).decode().strip()
    require(re.fullmatch(r'v1\.34\.\d+', version), 'bootstrap currently targets kubeadm 1.34.x; review before changing minor')
    identity = imds_identity()
    # Wait for a fresh publication; never retry kubeadm by resetting a partial node.
    for attempt in range(10):
        try:
            raw = aws(c, 'ssm', 'get-parameter', '--name', c['join_config_parameter'], '--with-decryption', '--output', 'json')
            b = json.loads(json.loads(raw)['Parameter']['Value'])
            doc = make_join(b, c, identity, int(time.time()))
            break
        except (ContractError, ValueError, KeyError, TypeError):
            if attempt == 9:
                raise ContractError('no valid fresh join bundle after 10 attempts')
            time.sleep(30)
    with tempfile.TemporaryDirectory(prefix='karpenter-join-', dir='/run') as d:
        path = Path(d) / 'join.json'
        path.write_text(json.dumps(doc)); path.chmod(0o600)
        command(['kubeadm', 'join', '--config', str(path)], timeout=300)
    print('kubeadm join completed; controller registration and Pod readiness still require verification')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['publish', 'join'])
    p.add_argument('--config', type=Path, required=True)
    p.add_argument('--execute', action='store_true')
    args = p.parse_args()
    require(args.execute, 'runtime execution requires --execute')
    require(os.name == 'posix' and os.geteuid() == 0, 'requires Linux root')
    os.umask(0o077)
    c = json.loads(args.config.read_text())
    # One designated publisher host; this lock only prevents overlapping local runs.
    import fcntl
    with open('/run/doktori-karpenter-' + args.mode + '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        (publish if args.mode == 'publish' else join)(c)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # No traceback or raw input/command output: a malformed SSM payload can contain secrets.
        print('karpenter bootstrap failed: ' + (str(exc) if isinstance(exc, ContractError) else type(exc).__name__))
        raise SystemExit(1)
