#!/usr/bin/env bash
set -euo pipefail

SERIAL=""
PORT=27183
JAR=""
REMOTE_JAR="/data/local/tmp/screencast-server.jar"
STOP=0

usage() {
  cat <<'EOF'
Usage: adb_launch.sh [--serial SERIAL] [--port PORT] [--jar PATH]
                     [--remote-jar PATH] [--stop]

The capture server is launched with `adb shell`, so it runs as the shell user.
The jar must already be built; see android-server/README.md.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      SERIAL="${2:?missing value for --serial}"
      shift 2
      ;;
    --port)
      PORT="${2:?missing value for --port}"
      shift 2
      ;;
    --jar)
      JAR="${2:?missing value for --jar}"
      shift 2
      ;;
    --remote-jar)
      REMOTE_JAR="${2:?missing value for --remote-jar}"
      shift 2
      ;;
    --stop)
      STOP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ADB=(adb)
if [[ -n "$SERIAL" ]]; then
  ADB+=(-s "$SERIAL")
fi

if [[ "$STOP" -eq 1 ]]; then
  "${ADB[@]}" shell "pkill -f com.example.screencast.server.Server" || true
  "${ADB[@]}" forward --remove "tcp:$PORT" || true
  echo "Requested stop and removed tcp:$PORT forwarding."
  exit 0
fi

if [[ -n "$JAR" ]]; then
  if [[ ! -f "$JAR" ]]; then
    echo "Server jar not found: $JAR" >&2
    exit 1
  fi
  "${ADB[@]}" push "$JAR" "$REMOTE_JAR"
fi

"${ADB[@]}" forward "tcp:$PORT" "tcp:$PORT"

echo "Forwarding 127.0.0.1:$PORT -> device, launching app_process as shell."
echo "Press Ctrl+C to end the adb shell session."

"${ADB[@]}" shell \
  "CLASSPATH=$REMOTE_JAR app_process /system/bin com.example.screencast.server.Server --port=$PORT"
