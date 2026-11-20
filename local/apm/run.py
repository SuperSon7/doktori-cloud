"""Local-only APM runner. Does not invoke AWS, Terraform apply or remote Docker."""
import argparse, hashlib, json, os, secrets, shutil, subprocess, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / ".runtime"
AGENT_VERSION = "2.23.0"
AGENT_URL = f"https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v{AGENT_VERSION}/opentelemetry-javaagent.jar"
def docker(*args):
    return subprocess.check_output(["docker", "--context", "desktop-linux", *args], text=True).strip()
def guard():
    ctx = json.loads(docker("context", "inspect", "desktop-linux"))[0]
    if ctx["Endpoints"]["docker"]["Host"] != "npipe:////./pipe/dockerDesktopLinuxEngine":
        raise SystemExit("Local Docker Desktop Linux endpoint required")
    if docker("info", "--format", "{{.OSType}}") != "linux":
        raise SystemExit("Linux engine required")
def compose(*args):
    guard()
    subprocess.run(["docker", "--context", "desktop-linux", "compose", "--env-file", str(RUNTIME / ".env"), "-f", str(ROOT / "compose.yaml"), *args], check=True)
def init():
    RUNTIME.mkdir(exist_ok=True)
    env = RUNTIME / ".env"
    if not env.exists():
        env.write_text("".join(f"{k}={secrets.token_hex(24)}\n" for k in ["DB_PASSWORD", "DB_ROOT_PASSWORD", "GRAFANA_PASSWORD"]))
    agent = RUNTIME / "otel.jar"
    if not agent.exists():
        with urllib.request.urlopen(AGENT_URL, timeout=90) as response:
            payload = response.read()
        agent.write_bytes(payload)
    digest = hashlib.sha256(agent.read_bytes()).hexdigest()
    lock = ROOT / "agent.lock.json"
    if lock.exists():
        expected = json.loads(lock.read_text())
        if digest != expected["sha256"] or expected["version"] != AGENT_VERSION:
            raise SystemExit("Agent SHA256 mismatch; do not execute")
    else:
        lock.write_text(json.dumps(dict(version=AGENT_VERSION,url=AGENT_URL,sha256=digest,trust="first HTTPS download; subsequent runs hash-checked"),indent=2)+"\n")
    backend = ROOT.parents[2] / "doktori-backend" / "apm-lab" / "build" / "libs" / "apm-pilot.jar"
    if not backend.exists(): raise SystemExit(f"Build backend/apm-lab first: {backend}")
    shutil.copyfile(backend, RUNTIME / "apm-pilot.jar")
    print("Local secrets preserved; agent hash checked; API jar staged")
if __name__ == "__main__":
    parser=argparse.ArgumentParser(); parser.add_argument("action",choices=["init","up","stop","status","check"]);args=parser.parse_args()
    if args.action=="init": init()
    elif args.action=="up": compose("up","-d")
    elif args.action=="stop": compose("stop")
    elif args.action=="status": compose("ps")
    else:
        guard()
        subprocess.run([os.sys.executable,str(ROOT/"verify.py")],check=True)
