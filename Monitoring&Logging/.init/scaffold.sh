#!/usr/bin/env bash
set -euo pipefail
WS="/home/kavia/workspace/code-generation/test-project-ajay-8050-8167/Monitoring&Logging"
mkdir -p "$WS/src" "$WS/tests"
# requirements
cat > "$WS/requirements.txt" <<'REQ'
fastapi>=0.95,<2
uvicorn[standard]
celery>=5.2,<6
python-dotenv
requests
pytest
REQ
# .env template
cat > "$WS/.env" <<'ENV'
APP_HOST=127.0.0.1
APP_PORT=8000
CELERY_BROKER_URL=memory://
ENV=development
ENV_SECRET=devsecret
USE_RELOAD=false
USE_REDIS=false
ENV
# package init
cat > "$WS/src/__init__.py" <<'PY'
# src package
PY
# minimal FastAPI app
cat > "$WS/src/main.py" <<'PY'
from fastapi import FastAPI
app = FastAPI()

@app.get('/health')
async def health():
    return {'status':'ok'}
PY
# celery app with robust dotenv path discovery
cat > "$WS/src/celery_app.py" <<'PY'
from pathlib import Path
from celery import Celery
from dotenv import load_dotenv
import os

# discover project root and .env reliably
root = Path(__file__).resolve().parents[1]
env_path = root / '.env'
if env_path.exists():
    load_dotenv(dotenv_path=str(env_path))
else:
    # fallback to default load from environment / CWD
    load_dotenv()

broker = os.getenv('CELERY_BROKER_URL', 'memory://')
cel = Celery('monitoring_logging', broker=broker)
# if using memory broker, run tasks eagerly for tests
if broker.startswith('memory'):
    cel.conf.task_always_eager = True

@cel.task
def ping(x):
    return x
PY
# start script: explicitly use venv uvicorn binary
cat > "$WS/start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
WS="/home/kavia/workspace/code-generation/test-project-ajay-8050-8167/Monitoring&Logging"
UV_BIN="$WS/.venv/bin/uvicorn"
if [ ! -x "$UV_BIN" ]; then
  echo "uvicorn binary not found in venv: $UV_BIN" >&2
  exit 3
fi
cd "$WS"
HOST=${APP_HOST:-0.0.0.0}
PORT=${APP_PORT:-8000}
if [ "${USE_RELOAD:-false}" = "true" ]; then
  exec "$UV_BIN" src.main:app --host "$HOST" --port "$PORT" --reload
else
  exec "$UV_BIN" src.main:app --host "$HOST" --port "$PORT"
fi
SH
chmod +x "$WS/start.sh"
# pytest health test
cat > "$WS/tests/test_health.py" <<'PY'
import os
import requests

def test_health():
    host = os.getenv('APP_HOST','127.0.0.1')
    port = int(os.getenv('APP_PORT','8000'))
    url = f'http://{host}:{port}/health'
    r = requests.get(url, timeout=5)
    assert r.status_code == 200
PY
# housekeeping
cat > "$WS/.gitignore" <<'GI'
.venv/
__pycache__/
*.pyc
GI
cat > "$WS/README.md" <<'RD'
# Monitoring&Logging - dev workspace

Minimal FastAPI + Celery scaffold for development and testing.
RD
cat > "$WS/pytest.ini" <<'PI'
[pytest]
minversion = 6.0
addopts = -q
testpaths = tests
PI

echo "scaffold: files created in $WS"
