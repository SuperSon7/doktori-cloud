import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from join_runtime import ContractError, validate_bundle, make_join, command, publish, join, put_bundle
from render import render


class WorkerJoinContract(unittest.TestCase):
    def setUp(self):
        self.c=json.loads(Path(__file__).with_name('inputs.example.json').read_text())
        self.now=100000
        self.b={'schema':1,'cluster_name':self.c['cluster_name'],'endpoint':self.c['cluster_endpoint'],
                'ca_spki_hash':self.c['ca_spki_hash'],'token':'abcdef.0123456789abcdef',
                'issued_at':self.now-100,'expires_at':self.now+3000}
        self.identity={'id':'i-0123456789abcdef0','az':'ap-northeast-2a','name':'ip-10-1-2-3.ap-northeast-2.compute.internal'}

    def test_join_binds_ec2_identity_and_trust(self):
        doc=make_join(self.b,self.c,self.identity,self.now)
        args={x['name']:x['value'] for x in doc['nodeRegistration']['kubeletExtraArgs']}
        self.assertEqual(args['provider-id'],'aws:///ap-northeast-2a/i-0123456789abcdef0')
        self.assertEqual(doc['discovery']['bootstrapToken']['caCertHashes'],[self.c['ca_spki_hash']])
        self.assertEqual(doc['nodeRegistration']['taints'][0]['effect'],'NoExecute')

    def test_rejects_wrong_trust_and_command_injection(self):
        for key,value in [('endpoint','https://attacker.invalid:6443'),('cluster_name','other'),
                          ('ca_spki_hash','sha256:'+'1'*64),('token','abcdef.0123456789abcdef; curl attacker')]:
            with self.subTest(field=key):
                bad=copy.deepcopy(self.b);bad[key]=value
                with self.assertRaises(ContractError):validate_bundle(bad,self.c,self.now)
        bad=dict(self.b,command='kubeadm reset -f')
        with self.assertRaises(ContractError):validate_bundle(bad,self.c,self.now)

    def test_rejects_expired_short_future_and_unbounded_tokens(self):
        for issued,expiry in [(self.now-1000,self.now-1),(self.now,self.now+299),
                              (self.now+120,self.now+3500),(self.now,self.now+7200)]:
            with self.subTest(issued=issued,expiry=expiry):
                with self.assertRaises(ContractError):
                    validate_bundle(dict(self.b,issued_at=issued,expires_at=expiry),self.c,self.now)

    def test_join_identity_cannot_supply_flags(self):
        for key,value in [('id','i-abcd --flag'),('az','us-east-1a'),('name','node; touch /tmp/x')]:
            with self.assertRaises(ContractError):make_join(self.b,self.c,dict(self.identity,**{key:value}),self.now)

    def test_cli_failures_do_not_leak_output_or_retry_mutations(self):
        with patch('join_runtime.subprocess.run',return_value=subprocess.CompletedProcess([],1,b'',b'abcdef.0123456789abcdef')):
            with self.assertRaises(ContractError) as raised:command(['kubeadm','join'])
            self.assertNotIn(self.b['token'],str(raised.exception))

    def test_existing_node_never_reset(self):
        with patch('join_runtime.Path.exists',return_value=True),patch('join_runtime.command') as run:
            with self.assertRaises(ContractError):join(self.c)
            run.assert_not_called()

    def test_wrong_publisher_ca_never_issues_token_or_writes_ssm(self):
        with patch('join_runtime.command',side_effect=[b'public',b'not-the-pinned-key']) as run,patch('join_runtime.put_bundle') as put:
            with self.assertRaises(ContractError):publish(self.c)
            self.assertEqual(run.call_count,2)
            put.assert_not_called()

    def test_userdata_contains_code_and_public_pins_but_not_join_token(self):
        script=render(self.c)['ec2nodeclass.yaml']['spec']['userData']
        self.assertLess(len(script.encode()),16384)
        self.assertNotIn(self.b['token'],script)
        self.assertNotIn('kubeadm reset',script)
        self.assertNotIn('autoscaling',script)

    def test_ssm_write_uses_private_file_and_cleans_up_on_failure(self):
        temporary = tempfile.TemporaryDirectory
        observed=[]
        def fail_aws(c,*args):
            self.assertNotIn(self.b['token'],' '.join(args))
            request=Path(args[-1].removeprefix('file://'));observed.append(request)
            body=json.loads(request.read_text())
            self.assertEqual(json.loads(body['Value']),self.b)
            self.assertEqual(body['Type'],'SecureString')
            raise ContractError('synthetic SSM failure')
        with patch('join_runtime.tempfile.TemporaryDirectory',side_effect=lambda **kw:temporary()),patch('join_runtime.aws',side_effect=fail_aws):
            with self.assertRaises(ContractError):put_bundle(self.c,self.b)
        self.assertFalse(observed[0].exists())

    def test_kubeadm_failure_removes_join_file_without_reset(self):
        temporary = tempfile.TemporaryDirectory
        observed=[]
        calls=[]
        def run(argv,**kwargs):
            calls.append(argv)
            if argv[1]=='version':return b'v1.34.6'
            self.assertEqual(argv[:3],['kubeadm','join','--config'])
            p=Path(argv[3]);observed.append(p)
            self.assertEqual(json.loads(p.read_text())['discovery']['bootstrapToken']['token'],self.b['token'])
            raise ContractError('synthetic kubeadm failure')
        raw=json.dumps({'Parameter':{'Value':json.dumps(self.b)}}).encode()
        with patch('join_runtime.Path.exists',return_value=False),patch('join_runtime.imds_identity',return_value=self.identity),patch('join_runtime.aws',return_value=raw),patch('join_runtime.time.time',return_value=self.now),patch('join_runtime.tempfile.TemporaryDirectory',side_effect=lambda **kw:temporary()),patch('join_runtime.command',side_effect=run):
            with self.assertRaises(ContractError):join(self.c)
        self.assertFalse(observed[0].exists())
        self.assertEqual(len(calls),2)


if __name__=='__main__':unittest.main()
