#!/usr/bin/env bash
set -euo pipefail
# Validation driver script - implements full validation as specified
WS="/home/kavia/workspace/code-generation/test-project-ajay-8050-8167/Monitoring&Logging"
cd "$WS"
export PATH="$WS/.venv/bin:$PATH"
VENV_PY="$WS/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
  echo "ERROR: venv python not found at $VENV_PY" >&2
  exit 2
fi
# BUILD: ensure src.main import works
if ! $VENV_PY -c "import importlib; importlib.import_module('src.main')"; then
  echo 'build check failed: cannot import src.main' >&2
  exit 4
fi
# START app in a new session
export USE_RELOAD=false
setsid bash -lc "APP_HOST=127.0.0.1 APP_PORT=8000 '$WS/start.sh'" >/dev/null 2>&1 &
APP_PID=$!
# robust PGID retrieval
APP_PGID=""
for i in 1 2 3 4 5; do
  if APP_PGID=$(ps -o pgid= "$APP_PID" 2>/dev/null | tr -d ' '); then [ -n "$APP_PGID" ] && break; fi
  sleep 0.2
done
if [ -z "$APP_PGID" ]; then
  echo 'failed to obtain PGID for app' >&2
  kill -TERM "$APP_PID" >/dev/null 2>&1 || true
  exit 5
fi
# wait for health
ATTEMPTS=60
SLEEP=0.5
i=0
while [ $i -lt $ATTEMPTS ]; do
  sleep $SLEEP
  if curl -sSf http://127.0.0.1:8000/health >/dev/null 2>&1; then break; fi
  i=$((i+1))
done
if [ $i -ge $ATTEMPTS ]; then
  echo 'server did not respond' >&2
  kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL -"$APP_PGID" >/dev/null 2>&1 || true
  exit 6
fi
# Determine broker using python-dotenv
BROKER=$($VENV_PY - <<'PY'
import os
from dotenv import load_dotenv
from pathlib import Path
root = Path(__file__).resolve().parents[1]
envf = root / '.env'
if envf.exists():
    load_dotenv(dotenv_path=str(envf))
else:
    load_dotenv()
print(os.getenv('CELERY_BROKER_URL','memory://'))
PY
)
BROKER=$(echo "$BROKER" | tr -d ' \r\n')
CELERY_WORKER_PGID=0
WORKER_LOG="$WS/celery_worker.log"
# If broker is redis and USE_REDIS=true, verify reachability then start worker from venv
if [ "${USE_REDIS:-false}" = "true" ] && (echo "$BROKER" | grep -qi '^redis'); then
  REDIS_HOST=127.0.0.1
  REDIS_PORT=6379
  # crude parse for host:port if present
  if echo "$BROKER" | grep -qi '^redis://'; then
    # attempt extraction: redis://[:pass@]host:port/...
    hostport=$(echo "$BROKER" | sed -E 's|^redis://([^/@]+@)?([^:/]+)(:([0-9]+))?.*|\2:\4|')
    if [[ $hostport =~ :([0-9]+)$ ]]; then
      maybeport=${BASH_REMATCH[1]}
      [[ -n "$maybeport" ]] && REDIS_PORT=$maybeport || true
    fi
    hp=$(echo "$hostport" | cut -d: -f1)
    [[ -n "$hp" && "$hp" != "$hostport" ]] && REDIS_HOST=$hp || true
  fi
  if ! (bash -c "</dev/tcp/$REDIS_HOST/$REDIS_PORT") >/dev/null 2>&1; then
    echo "Redis broker not reachable at $REDIS_HOST:$REDIS_PORT" >&2
    kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
    exit 7
  fi
  # ensure celery binary exists in venv
  if [ ! -x "$WS/.venv/bin/celery" ]; then
    echo "ERROR: celery binary not present in venv at $WS/.venv/bin/celery" >&2
    kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
    exit 11
  fi
  # start celery worker using venv celery; write logs for diagnostics
  rm -f "$WORKER_LOG" || true
  setsid bash -lc "'$WS/.venv/bin/celery' -A src.celery_app:cel worker --loglevel=INFO --concurrency=1 >> '$WORKER_LOG' 2>&1" >/dev/null 2>&1 &
  CELERY_WORKER_PID=$!
  # obtain PGID
  for i in 1 2 3 4 5; do
    if CELERY_WORKER_PGID=$(ps -o pgid= "$CELERY_WORKER_PID" 2>/dev/null | tr -d ' '); then [ -n "$CELERY_WORKER_PGID" ] && break; fi
    sleep 0.2
  done
  if [ -z "$CELERY_WORKER_PGID" ]; then
    echo 'failed to obtain PGID for celery worker' >&2
    kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
    exit 8
  fi
  # wait for worker to announce readiness in log (timeout)
  READY=false
  for i in {1..30}; do
    sleep 1
    if [ -f "$WORKER_LOG" ]; then
      if grep -qi "ready" "$WORKER_LOG" >/dev/null 2>&1 || grep -qi "connected to" "$WORKER_LOG" >/dev/null 2>&1; then
        READY=true && break
      fi
    fi
  done
  if [ "$READY" != true ]; then
    echo 'celery worker did not become ready; last logs:' >&2
    tail -n 50 "$WORKER_LOG" >&2 || true
    kill -TERM -"$CELERY_WORKER_PGID" >/dev/null 2>&1 || true
    kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
    exit 9
  fi
fi
# run quick celery task; memory broker runs eagerly in-process
PYCODE="from src.celery_app import ping; r=ping.apply_async((42,)).get(timeout=10); print('CELERY TASK RESULT:', r)"
set +e
TASK_OUT=$($VENV_PY -c "$PYCODE" 2>&1)
RC=$?
set -e
# capture result and logs
echo "$TASK_OUT"
if [ $RC -ne 0 ]; then
  echo 'celery task validation failed' >&2
  if [ -f "$WORKER_LOG" ]; then
    echo '--- worker log tail ---' >&2
    tail -n 100 "$WORKER_LOG" >&2 || true
  fi
fi
# cleanup celery worker if started
if [ "$CELERY_WORKER_PGID" != "0" ] && [ -n "$CELERY_WORKER_PGID" ]; then
  kill -TERM -"$CELERY_WORKER_PGID" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL -"$CELERY_WORKER_PGID" >/dev/null 2>&1 || true
fi
# stop app
kill -TERM -"$APP_PGID" >/dev/null 2>&1 || true
sleep 1
kill -KILL -"$APP_PGID" >/dev/null 2>&1 || true
if [ $RC -ne 0 ]; then
  exit 10
fi
echo 'VALIDATION: OK'
