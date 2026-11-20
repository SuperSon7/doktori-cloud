"""Check the real root variable validation in an isolated provider-free module."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--terraform',default='terraform')
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='doktori-ha-inputs-') as directory:
    work=Path(directory)
    (work/'variables.tf').write_text((root/'terraform/environments/prod/data/variables.tf').read_text(encoding='utf-8'),encoding='utf-8')
    (work/'tests').mkdir()
    (work/'tests/inputs.tftest.hcl').write_text('''
run "single_node_defaults" { command = plan }
run "missing_ha_image" {
  command = plan
  variables { enable_redis_ha = true }
  expect_failures = [var.ha_ami_ids]
}
run "invalid_ha_image" {
  command = plan
  variables {
    enable_rabbitmq_ha = true
    ha_ami_ids = { rabbitmq = "unreviewed" }
  }
  expect_failures = [var.ha_ami_ids]
}
run "explicit_image_shape" {
  command = plan
  variables {
    enable_mongodb_ha = true
    ha_ami_ids = { mongodb = "ami-0123456789abcdef0" }
  }
}
''',encoding='utf-8')
    # The directory contains ONLY variables + command=plan tests; no provider,
    # backend, resources, remote state or AWS data source is copied here.
    subprocess.run([args.terraform,'init','-backend=false','-input=false','-no-color'],cwd=work,check=True)
    subprocess.run([args.terraform,'test','-no-color'],cwd=work,check=True)
