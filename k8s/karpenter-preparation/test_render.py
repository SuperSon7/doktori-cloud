import copy
import json
from pathlib import Path
import unittest
import yaml
from render import render


class PreparationContract(unittest.TestCase):
    def setUp(self):
        self.config=json.loads(Path(__file__).with_name('inputs.example.json').read_text())

    def test_identity_bound_to_one_service_account_and_separate_token(self):
        files=render(self.config)
        condition=files['controller-trust.json']['Statement'][0]['Condition']['StringEquals']
        self.assertEqual(set(condition.values()),{'sts.amazonaws.com','system:serviceaccount:karpenter:karpenter'})
        helm=files['helm-values.yaml']; env={x['name']:x['value'] for x in helm['controller']['env']}
        token=helm['extraVolumes'][0]['projected']['sources'][0]['serviceAccountToken']
        self.assertEqual(token['audience'],'sts.amazonaws.com')
        self.assertEqual(env['AWS_EC2_METADATA_DISABLED'],'true')
        self.assertEqual(env['EKS_CONTROL_PLANE'],'false')
        self.assertNotIn('AWS_ACCESS_KEY_ID',env)
        self.assertEqual(helm['serviceAccount']['name'],'karpenter')

    def test_scope_and_custom_bootstrap_guards(self):
        files=render(self.config); pool=files['nodepool.yaml']['spec']; node=files['ec2nodeclass.yaml']['spec']
        self.assertEqual(pool['disruption']['budgets'],[{'nodes':'0'}])
        self.assertEqual(pool['template']['spec']['expireAfter'],'Never')
        self.assertEqual(node['amiFamily'],'Custom')
        self.assertIn('join --config /etc/doktori-karpenter/worker.json --execute',node['userData'])
        self.assertNotIn('eval ',node['userData'])
        self.assertNotIn('kubeadm reset',node['userData'])
        args={x['name']:x['value'] for x in files['join-config.template.yaml']['nodeRegistration']['kubeletExtraArgs']}
        self.assertEqual(int(args['max-pods']),node['kubelet']['maxPods'])
        for name,value in files.items():
            self.assertEqual(yaml.safe_load(yaml.safe_dump(value)),value)

    def test_no_implicit_approval_or_unreviewed_chart(self):
        bad=copy.deepcopy(self.config);bad['deployment_approved']=True
        with self.assertRaises(ValueError):render(bad)
        bad=copy.deepcopy(self.config);bad['chart_reference']='latest'
        with self.assertRaises(ValueError):render(bad)
        bad=copy.deepcopy(self.config);bad['issuer']='https://oidc.example.invalid/?query=1'
        with self.assertRaises(ValueError):render(bad)


if __name__=='__main__':unittest.main()
