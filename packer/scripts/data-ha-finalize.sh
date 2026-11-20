#!/usr/bin/env bash
# Runs only inside a disposable Packer builder, after package setup.
set -euo pipefail
[[ "${DOKTORI_IMAGE_BUILD:-}" == "1" ]] || { echo 'Packer build marker required' >&2; exit 1; }
case "${DATA_SERVICE:-}" in
  redis) services=(redis-server redis-sentinel); redis-server --version; redis-sentinel --version ;;
  rabbitmq) services=(rabbitmq-server); rabbitmq-plugins list --enabled --minimal ;;
  mongodb) services=(mongod); mongod --version; mongosh --version ;;
  *) echo 'Unknown data service' >&2; exit 1 ;;
esac
# EC2 user_data enables these after runtime identity, auth and peers are ready.
systemctl disable --now "${services[@]}" alloy
if [[ "$DATA_SERVICE" == "rabbitmq" ]]; then
  # Local Erlang CLI commands can create a root cookie even after broker cleanup.
  rm -f /root/.erlang.cookie /home/ubuntu/.erlang.cookie /var/lib/rabbitmq/.erlang.cookie
fi
install -m 0755 -d /opt/doktori
python3 - <<'PY'
import json, os, platform, subprocess
from pathlib import Path
packages = subprocess.check_output(['dpkg-query','-W','-f=${binary:Package}=${Version}\n'],text=True)
prefixes=('redis','rabbitmq','erlang','mongodb','alloy')
metadata={'service':os.environ['DATA_SERVICE'],'architecture':platform.machine(),
          'packages':[line for line in packages.splitlines() if line.startswith(prefixes)],
          'runtime_credentials_baked':False,'data_services_enabled':False}
Path('/opt/doktori/image-build.json').write_text(json.dumps(metadata,indent=2)+'\n')
PY
chmod 0644 /opt/doktori/image-build.json
# Remove host identity from this disposable image; Ubuntu cloud-init regenerates it.
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --machine-id
