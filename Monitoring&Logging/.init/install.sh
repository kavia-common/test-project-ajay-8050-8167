#!/usr/bin/env bash
set -euo pipefail
# Install Python dependencies into workspace venv using venv pip; verify redis if requested; print diagnostics
WS="/home/kavia/workspace/code-generation/test-project-ajay-8050-8167/Monitoring&Logging"
cd "$WS"
VENV="$WS/.venv"
VENV_PY="$VENV/bin/python"
VENV_PIP="$VENV/bin/pip"
# Ensure venv exists; create if missing (non-interactive)
if [ ! -x "$VENV_PY" ]; then
  python3 -m venv "$VENV"
fi
# Upgrade pip in venv without touching global pip
"$VENV_PY" -m pip install --upgrade pip setuptools wheel >/dev/null
# Install requirements into venv; fail fast and show pip output on failure
if ! "$VENV_PIP" install --upgrade -r "$WS/requirements.txt"; then
  echo 'pip install failed' >&2
  "$VENV_PIP" --version || true
  exit 2
fi
# Print installed versions for diagnostics
"$VENV_PY" - <<'PY'
import sys
pkgs = ['fastapi','uvicorn','celery','python_dotenv','pytest']
for p in pkgs:
    try:
        m = __import__(p)
        print(p, getattr(m,'__version__', 'unknown'))
    except Exception:
        print(p, 'missing')
PY
# If USE_REDIS=true, verify reachability of REDIS_PORT; do not attempt to start system redis-server
if [ "${USE_REDIS:-false}" = "true" ]; then
  REDIS_PORT=${REDIS_PORT:-6379}
  if ! (bash -c "</dev/tcp/127.0.0.1/$REDIS_PORT") >/dev/null 2>&1; then
    echo "Redis not reachable at 127.0.0.1:$REDIS_PORT. Configure accessible Redis or set USE_REDIS=false to use memory broker." >&2
    exit 3
  fi
fi
# verify critical imports
"$VENV_PY" - <<'PY'
import sys
try:
    import fastapi, celery, dotenv, requests
except Exception as e:
    print('dependency import failed:', e, file=sys.stderr)
    sys.exit(4)
print('deps-ok')
PY
