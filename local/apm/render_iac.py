"""Render provider-free runtime artifacts; never apply or contact cloud APIs."""
import argparse,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--terraform',required=True);args=parser.parse_args()
module=ROOT.parents[1]/'terraform/modules/apm-runtime'
result=subprocess.run([args.terraform,f'-chdir={module}','console','-var=enabled=true'],input='jsonencode({env=local.environment, java_argument=local.agent_argument, agent=local.agent})\n',text=True,capture_output=True,check=True)
data=json.loads(json.loads(result.stdout.strip()))
out=ROOT/'.runtime/native';out.mkdir(parents=True,exist_ok=True)
(out/'api.env').write_text(''.join(f'{k}={v}\n' for k,v in sorted(data['env'].items())))
(out/'java-argument.txt').write_text(data['java_argument']+'\n')
# module's tested output is rendered through a temporary no-resource root console.
example=ROOT.parents[1]/'terraform/environments/local/apm'
result=subprocess.run([args.terraform,f'-chdir={example}','console'],input='jsonencode(module.api_apm.install_script)\n',text=True,capture_output=True,check=True)
(out/'install-agent.sh').write_text(json.loads(json.loads(result.stdout.strip())),newline='\n')
print('Rendered .runtime/native: api.env, java-argument.txt, install-agent.sh. No apply.')
