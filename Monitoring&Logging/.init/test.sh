#!/usr/bin/env bash
set -euo pipefail

# Testing script: start app using venv uvicorn via start.sh, wait for /health, run pytest, then cleanly kill PGID
WS="/home/kavia/workspace/code-generation/test-project-ajay-8050-8167/Monitoring&Logging"
cd "$WS"
export PATH="$WS/.venv/bin:$PATH"
export USE_RELOAD=false
HOST=${APP_HOST:-127.0.0.1}
PORT=${APP_PORT:-8000}

# start server in new session; start.sh must use the venv uvicorn binary
setsid bash -lc "APP_HOST=$HOST APP_PORT=$PORT '$WS/start.sh'" >/dev/null 2>&1 &
PID=$!

# robustly obtain PGID with retries (avoid race conditions)
PGID=""
for _ in 1 2 3 4 5; do
  if PGID=$(ps -o pgid= "$PID" 2>/dev/null | tr -d ' '); then
    [ -n "$PGID" ] && break
  fi
  sleep 0.2
done
if [ -z "$PGID" ]; then
  echo 'failed to obtain PGID for server process' >&2
  kill -TERM "$PID" >/dev/null 2>&1 || true
  exit 4
fi

# wait for readiness (max ~30s)
ATTEMPTS=60
SLEEP=0.5
i=0
while [ $i -lt $ATTEMPTS ]; do
  sleep $SLEEP
  if curl -sSf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  i=$((i+1))
done
if [ $i -ge $ATTEMPTS ]; then
  echo 'server did not become ready in time' >&2
  kill -TERM -"$PGID" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL -"$PGID" >/dev/null 2>&1 || true
  exit 5
fi

# run pytest using venv pytest
"$WS/.venv/bin/pytest" -q "$WS/tests" || {
  kill -TERM -"$PGID" >/dev/null 2>&1 || true
  sleep 1
  kill -KILL -"$PGID" >/dev/null 2>&1 || true
  exit 6
}

# clean shutdown
kill -TERM -"$PGID" >/dev/null 2>&1 || true
sleep 1
kill -KILL -"$PGID" >/dev/null 2>&1 || true
