"""Offline release integrity, Helm rendering and CRD structural validation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import tarfile
import yaml
import jsonschema
from render import render


def verify(helm, bash=None):
    here=Path(__file__).resolve().parent
    lock=json.loads((here/'upstream/release-lock.json').read_text())
    assert {'architecture':'arm64','os':'linux'} in lock['controller_platforms']
    for name,digest in lock['files'].items():
        assert hashlib.sha256((here/'upstream'/name).read_bytes()).hexdigest()==digest, name
    with tarfile.open(here/'upstream/karpenter-1.15.2.tgz','r:gz') as archive:
        chart=yaml.safe_load(archive.extractfile('karpenter/Chart.yaml').read())
        assert str(chart['version'])==lock['version']
        assert str(chart['appVersion'])==lock['version']
    config=json.loads((here/'inputs.example.json').read_text())
    artifacts=render(config)
    with tempfile.TemporaryDirectory() as d:
        directory=Path(d)
        values=directory/'values.yaml';values.write_text(yaml.safe_dump(artifacts['helm-values.yaml']))
        run=subprocess.run([helm,'template','karpenter',str(here/'upstream/karpenter-1.15.2.tgz'),
            '--namespace','karpenter','--kube-version','1.34.0','--include-crds','-f',str(values)],
            check=True,capture_output=True,text=True,encoding='utf-8')
        docs=[x for x in yaml.safe_load_all(run.stdout) if x]
        deploy=next(x for x in docs if x['kind']=='Deployment')
        pod=deploy['spec']['template']['spec'];controller=pod['containers'][0]
        assert controller['image'].endswith('@'+lock['controller_digest'])
        env=controller['env'];assert len({e['name'] for e in env})==len(env)
        env={e['name']:e.get('value') for e in env}
        assert env['EKS_CONTROL_PLANE']=='false' and env['AWS_EC2_METADATA_DISABLED']=='true'
        assert env['AWS_ROLE_ARN']==f"arn:aws:iam::{config['account_id']}:role/{config['controller_role_name']}"
        projected=next(v for v in pod['volumes'] if v['name']=='aws-iam-token')['projected']['sources'][0]
        assert projected['serviceAccountToken']['audience']=='sts.amazonaws.com'
        assert pod['nodeSelector']['doktori.io/node-role']=='system'
        schemas={x['spec']['names']['kind']:next(v['schema']['openAPIV3Schema'] for v in x['spec']['versions'] if v['name']=='v1')
                 for x in docs if x['kind']=='CustomResourceDefinition' and x['spec']['names']['kind'] in ('NodePool','EC2NodeClass')}
        for name in ('nodepool.yaml','ec2nodeclass.yaml'):
            doc=artifacts[name];jsonschema.Draft7Validator(schemas[doc['kind']]).validate(doc)
        if bash:
            script=directory/'bootstrap.sh';script.write_text(artifacts['ec2nodeclass.yaml']['spec']['userData'],encoding='utf-8')
            subprocess.run([bash,'-n',str(script).replace('\\','/')],check=True,capture_output=True)
    result={'scope':'offline only; no AWS or cluster access','chart_version':chart['version'],
            'controller_digest':lock['controller_digest'],'helm_documents':len(docs),
            'checks':['upstream file hashes','OCI chart version','image digest','unique environment names',
                      'separate STS projection','fixed system node selector','NodePool/NodeClass structural schemas'],
            'limitations':['no Kubernetes CEL/admission validation','no AWS IAM simulator','no live join or issuer verification']}
    if bash:result['checks'].append('rendered userData bash syntax')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--helm',required=True);p.add_argument('--bash');p.add_argument('--output',type=Path)
    a=p.parse_args();result=verify(a.helm,a.bash)
    if a.output:a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
