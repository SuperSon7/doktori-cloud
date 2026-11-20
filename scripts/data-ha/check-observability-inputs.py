"""Test the actual inventory/monitor-selection expressions without AWS resources."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser=argparse.ArgumentParser();parser.add_argument('--terraform',default='terraform');args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
source=(root/'terraform/environments/prod/data/observability.tf').read_text(encoding='utf-8')
def block(prefix):
 start=source.index(prefix);first=source.index('{',start);level=1;end=first+1
 while level:
  if source[end]=='{':level+=1
  if source[end]=='}':level-=1
  end+=1
 return source[start:end]
with tempfile.TemporaryDirectory(prefix='doktori-observability-inputs-') as directory:
 p=Path(directory);(p/'tests').mkdir()
 declarations='\n'.join('variable "'+v+'" {\n type=bool\n default=false\n}' for v in ['enable_data_ha_observability','enable_data_ha','enable_redis_ha','enable_rabbitmq_ha','enable_mongodb_ha'])
 declarations+='\nvariable "project_name" { default="test" }\nvariable "environment" {default="test"}\n'
 module='module "topology" {\n source='+json.dumps((root/'terraform/modules/data-topology').as_posix())+'''
 networking={internal_zone_name="test.internal",subnet_cidrs={private_app="10.1.10.0/24",private_app_b="10.1.11.0/24",private_app_c="10.1.12.0/24"}}
 enable_data_ha=var.enable_data_ha
 enable_redis_ha=var.enable_redis_ha
 enable_rabbitmq_ha=var.enable_rabbitmq_ha
 enable_mongodb_ha=var.enable_mongodb_ha
}
locals {
'''+ '\n'.join(k+' = module.topology.config.'+k for k in ['redis_ha_enabled','rabbitmq_ha_enabled','mongodb_ha_enabled','redis_nodes','rabbitmq_nodes','mongodb_nodes'])+'\n}\n'
 (p/'main.tf').write_text(declarations+module+block('locals {')+'\n'+block('output "data_ha_observability_inventory"'),encoding='utf-8')
 test=''
 for name,flags,count,secrets in [('disabled',{},0,0),('only-feature-no-ha',{'enable_data_ha_observability':True},0,0),
   ('redis',{'enable_data_ha_observability':True,'enable_redis_ha':True},9,0),
   ('redis-mq',{'enable_data_ha_observability':True,'enable_redis_ha':True,'enable_rabbitmq_ha':True},18,1),
   ('all',{'enable_data_ha_observability':True,'enable_data_ha':True,'enable_mongodb_ha':True},24,2)]:
  test+='run "'+name+'" {\n command=plan\n'
  if flags:test+=' variables {\n'+'\n'.join(k+'='+str(v).lower() for k,v in flags.items())+'\n }\n'
  test+=' assert {\n condition=length(output.data_ha_observability_inventory.targets)=='+str(count)+' && length(local.ha_monitor_parameters)=='+str(secrets)+'\n error_message="Inventory and monitor secrets must match selected HA stage"\n }\n}\n'
 (p/'tests/inventory.tftest.hcl').write_text(test,encoding='utf-8')
 subprocess.run([args.terraform,'init','-backend=false','-no-color'],cwd=p,check=True,stdout=subprocess.DEVNULL)
 subprocess.run([args.terraform,'test','-no-color'],cwd=p,check=True)
