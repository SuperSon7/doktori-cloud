"""OFFLINE ONLY. Produce review templates; never contacts AWS/Kubernetes or applies files."""
import argparse
import base64
import gzip
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
import yaml
from join_runtime import validate_config


def runtime_config(c):
    config = {k:c[k] for k in ('cluster_name','region','cluster_endpoint','ca_spki_hash','join_config_parameter','max_pods')}
    validate_config(config)
    return config


def bootstrap(c):
    runtime = Path(__file__).with_name('join_runtime.py').read_bytes()
    encoded = base64.b64encode(gzip.compress(runtime, mtime=0)).decode()
    cfg = base64.b64encode(json.dumps(runtime_config(c)).encode()).decode()
    return f'''#!/bin/bash
set -euo pipefail
umask 077
for tool in python3 aws kubeadm containerd; do command -v "$tool" >/dev/null; done
test -f /etc/kubernetes/ecr-credential-provider-config.yaml
test -x /usr/local/bin/ecr-credential-provider
test ! -f /etc/kubernetes/kubelet.conf
install -d -m 0700 /etc/doktori-karpenter /usr/local/lib/doktori-karpenter
python3 - <<'PY'
import base64, gzip
from pathlib import Path
Path('/usr/local/lib/doktori-karpenter/join_runtime.py').write_bytes(gzip.decompress(base64.b64decode('{encoded}')))
Path('/etc/doktori-karpenter/worker.json').write_bytes(base64.b64decode('{cfg}'))
PY
python3 /usr/local/lib/doktori-karpenter/join_runtime.py join --config /etc/doktori-karpenter/worker.json --execute
'''


def render(c):
    runtime_config(c)
    if c['chart_reference'] != '1.15.2':
        raise ValueError('Review the new chart schema before changing the reference version')
    if c.get('deployment_approved') is not False:
        raise ValueError('Preparation renderer does not accept deployment approval')
    if not re.fullmatch(r'\d{12}', c['account_id']):raise ValueError('account_id')
    for field in ('cluster_name','controller_role_name','node_instance_profile'):
        if not re.fullmatch(r'[A-Za-z0-9_-]+', c[field]):raise ValueError(field)
    for field in ('issuer','cluster_endpoint'):
        u=urlsplit(c[field])
        if u.scheme!='https' or not u.hostname or u.query or u.fragment or u.username or u.password:
            raise ValueError(field)
    if c['issuer'].endswith('/') or urlsplit(c['issuer']).port:raise ValueError('issuer trailing slash/port')
    issuer=c['issuer'][8:]
    role='arn:aws:iam::'+c['account_id']+':role/'+c['controller_role_name']
    trust={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Federated':'arn:aws:iam::'+c['account_id']+':oidc-provider/'+issuer},
        'Action':'sts:AssumeRoleWithWebIdentity','Condition':{'StringEquals':{issuer+':aud':'sts.amazonaws.com',issuer+':sub':'system:serviceaccount:karpenter:karpenter'}}}]}
    discovery={'issuer':c['issuer'],'jwks_uri':c['issuer']+'/openid/v1/jwks',
        'response_types_supported':['id_token'],'subject_types_supported':['public'],
        'id_token_signing_alg_values_supported':['RS256']}
    release=json.loads(Path(__file__).with_name('upstream').joinpath('release-lock.json').read_text())
    values={'replicas':2,'serviceAccount':{'create':True,'name':'karpenter'},
        'nodeSelector':{'kubernetes.io/os':'linux','doktori.io/node-role':'system'},
        'hostNetwork':False,'dnsPolicy':'ClusterFirst',
        'podSecurityContext':{'fsGroup':65532},
        'extraVolumes':[{'name':'aws-iam-token','projected':{'defaultMode':420,'sources':[{'serviceAccountToken':{'audience':'sts.amazonaws.com','expirationSeconds':3600,'path':'token'}}]}}],
        'controller':{'image':{'tag':'1.15.2','digest':release['controller_digest']},'env':[{'name':k,'value':v} for k,v in {
            'AWS_REGION':c['region'],'AWS_DEFAULT_REGION':c['region'],'AWS_ROLE_ARN':role,
            'AWS_WEB_IDENTITY_TOKEN_FILE':'/var/run/secrets/aws-iam/token',
            'AWS_STS_REGIONAL_ENDPOINTS':'regional','AWS_EC2_METADATA_DISABLED':'true',
            'EKS_CONTROL_PLANE':'false','CLUSTER_CA_BUNDLE':c['cluster_ca_base64']}.items()],
            'extraVolumeMounts':[{'name':'aws-iam-token','mountPath':'/var/run/secrets/aws-iam','readOnly':True}],
            'resources':{'requests':{'cpu':'1','memory':'1Gi'},'limits':{'memory':'1Gi'}}},
        'settings':{'clusterName':c['cluster_name'],'clusterEndpoint':c['cluster_endpoint'],'interruptionQueue':''}}
    pool={'apiVersion':'karpenter.sh/v1','kind':'NodePool','metadata':{'name':'doktori-canary'},'spec':{
        'template':{'metadata':{'labels':{'doktori.io/capacity':'canary'}},'spec':{
            'nodeClassRef':{'group':'karpenter.k8s.aws','kind':'EC2NodeClass','name':'doktori-canary'},
            'taints':[{'key':'doktori.io/canary','value':'true','effect':'NoSchedule'}],
            'requirements':[{'key':k,'operator':'In','values':v} for k,v in {
                'kubernetes.io/arch':['arm64'],'kubernetes.io/os':['linux'],'karpenter.sh/capacity-type':['on-demand'],
                'node.kubernetes.io/instance-type':['m7g.large','m6g.large']}.items()],
            'expireAfter':'Never'}},
        'limits':{'cpu':'8','memory':'32Gi'},
        'disruption':{'consolidationPolicy':'WhenEmpty','consolidateAfter':'10m','budgets':[{'nodes':'0'}]}}}
    nodeclass={'apiVersion':'karpenter.k8s.aws/v1','kind':'EC2NodeClass','metadata':{'name':'doktori-canary'},'spec':{
        'amiFamily':'Custom','amiSelectorTerms':[{'id':c['ami_id']}],
        'instanceProfile':c['node_instance_profile'],
        'subnetSelectorTerms':[{'id':v} for v in c['subnet_ids']],
        'securityGroupSelectorTerms':[{'id':v} for v in c['security_group_ids']],
        'metadataOptions':{'httpEndpoint':'enabled','httpTokens':'required','httpPutResponseHopLimit':1},
        'kubelet':{'maxPods':c['max_pods']},
        'tags':{'doktori.io/purpose':'karpenter-canary'},
        'userData':bootstrap(c)}}
    # This is a merge fragment for existing ClusterConfiguration, never a replacement.
    apiserver={'apiServer':{'extraArgs':[
        {'name':'service-account-issuer','value':c['issuer']},
        {'name':'service-account-issuer','value':'RETAIN_EXISTING_ISSUER_DURING_MIGRATION'},
        {'name':'service-account-signing-key-file','value':'/etc/kubernetes/pki/sa.key'},
        {'name':'service-account-key-file','value':'/etc/kubernetes/pki/sa.pub'},
        {'name':'api-audiences','value':'RETAIN_EXISTING_KUBERNETES_API_AUDIENCES'}]}}
    join={'apiVersion':'kubeadm.k8s.io/v1beta4','kind':'JoinConfiguration',
        'discovery':{'bootstrapToken':{'apiServerEndpoint':urlsplit(c['cluster_endpoint']).netloc,
            'token':'RETRIEVE_SHORT_LIVED_TOKEN_AT_BOOT','caCertHashes':['sha256:REPLACE_WITH_CA_SPKI_HASH']}},
        'nodeRegistration':{'name':'REPLACE_WITH_EC2_PRIVATE_DNS','criSocket':'unix:///run/containerd/containerd.sock',
            'taints':[{'key':'karpenter.sh/unregistered','effect':'NoExecute'},{'key':'doktori.io/canary','value':'true','effect':'NoSchedule'}],
            'kubeletExtraArgs':[{'name':'provider-id','value':'aws:///REPLACE_AZ/REPLACE_INSTANCE_ID'},
                {'name':'max-pods','value':str(c['max_pods'])}]}}
    smoke={'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':'karpenter-canary','namespace':'karpenter'},
        'spec':{'replicas':1,'selector':{'matchLabels':{'app':'karpenter-canary'}},'template':{
            'metadata':{'labels':{'app':'karpenter-canary'}},'spec':{
                'nodeSelector':{'karpenter.sh/nodepool':'doktori-canary'},
                'tolerations':[{'key':'doktori.io/canary','operator':'Equal','value':'true','effect':'NoSchedule'}],
                'containers':[{'name':'pause','image':'registry.k8s.io/pause:3.10',
                    'resources':{'requests':{'cpu':'100m','memory':'32Mi'},'limits':{'memory':'32Mi'}},
                    'securityContext':{'allowPrivilegeEscalation':False,'readOnlyRootFilesystem':True,
                        'runAsNonRoot':True,'runAsUser':65532,'capabilities':{'drop':['ALL']},'seccompProfile':{'type':'RuntimeDefault'}}}]}}}}
    publisher=runtime_config(c);publisher['kms_key_arn']=c['kms_key_arn']
    return {'controller-trust.json':trust,'openid-configuration.json':discovery,
        'helm-values.yaml':values,'nodepool.yaml':pool,'ec2nodeclass.yaml':nodeclass,
        'apiserver-merge-fragment.yaml':apiserver,'join-config.template.yaml':join,
        'publisher-config.json':publisher,'canary.yaml':smoke}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=Path,default=Path(__file__).with_name('inputs.example.json'))
    p.add_argument('--output',type=Path,default=Path(__file__).with_name('.generated'));a=p.parse_args()
    artifacts=render(json.loads(a.input.read_text(encoding='utf-8')))
    a.output.mkdir(parents=True,exist_ok=False)
    for name,value in artifacts.items():
        content=json.dumps(value,indent=2)+'\n' if name.endswith('.json') else yaml.safe_dump(value,sort_keys=False)
        (a.output/(name+'.example')).write_text(content,encoding='utf-8')
    print(f'Prepared {len(artifacts)} review-only files. No network, discovery, credentials, deployment or execution.')


if __name__=='__main__':main()
