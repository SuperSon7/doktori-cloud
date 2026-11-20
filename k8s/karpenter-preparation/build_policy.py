"""Derive the reviewed self-managed/on-demand policy from pinned upstream IAM source."""
import json
from pathlib import Path
import yaml

class Loader(yaml.SafeLoader):
    pass
Loader.add_constructor('!Sub', lambda loader, node: loader.construct_scalar(node))
Loader.add_constructor('!Ref', lambda loader, node: loader.construct_scalar(node))
Loader.add_constructor('!GetAtt', lambda loader, node: loader.construct_scalar(node))


def build():
    here=Path(__file__).resolve().parent
    resources=yaml.load((here/'upstream/cloudformation-v1.15.2.yaml').read_text(), Loader=Loader)['Resources']
    policy=json.loads(resources['NodeLifecyclePolicy']['Properties']['PolicyDocument'])
    # Explicit selectors also constrain authorization, not only scheduling intent.
    policy['Statement'][0]['Resource']='__LAUNCH_INPUT_ARNS__'
    for statement in policy['Statement']:
        if statement['Sid']=='AllowScopedDeletion':
            statement['Action'].remove('ec2:RebootInstances')
    discovery=json.loads(resources['ResourceDiscoveryPolicy']['Properties']['PolicyDocument'])
    for statement in discovery['Statement']:
        if statement['Sid']=='AllowSSMReadActions':
            continue
        if statement['Sid']=='AllowInstanceProfileReadActions':
            statement['Resource']='${node_profile_arn}'
        policy['Statement'].append(statement)
    policy['Statement'].append({'Sid':'PassDedicatedNodeRole','Effect':'Allow','Action':'iam:PassRole',
        'Resource':'${node_role_arn}','Condition':{'StringEquals':{'iam:PassedToService':'ec2.amazonaws.com'}}})
    text=json.dumps(policy,indent=2)
    for old,new in {'AWS::Partition':'partition','AWS::Region':'region','AWS::AccountId':'account_id','ClusterName':'cluster_name'}.items():
        text=text.replace('${'+old+'}', '${'+new+'}')
    text=text.replace('"__LAUNCH_INPUT_ARNS__"','${jsonencode(launch_input_arns)}')
    # Scope account-owned artifacts; image/snapshot ARNs were replaced above.
    text=text.replace(':${region}:*:', ':${region}:${account_id}:')
    destination=here.parents[1]/'terraform/modules/karpenter-identity/controller-policy.json.tftpl'
    destination.write_text(text+'\n',encoding='utf-8')
    return text


if __name__=='__main__':
    build()
    print('controller policy generated offline from pinned source')
