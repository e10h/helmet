#!/usr/bin/env bash
set -e

# ==============================================================================
# ON-PI YOLO OBJECT DETECTION & STREAMING
# Runs YOLO on Raspberry Pi 5, overlays bounding boxes, and streams to Mac ffplay
# ==============================================================================

PI_HOST="${PI_HOST:-ethan@pi5.local}"
PORT="${PORT:-8888}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
FPS="${FPS:-30}"
MODEL="${MODEL:-yolov8n.pt}"
CLIENT_IP="${CLIENT_IP:-}"

# Detect Mac IP
if [[ -z "$CLIENT_IP" ]]; then
    TARGET_NAME="${PI_HOST#*@}"
    IFACE=$(route get "$TARGET_NAME" 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$IFACE" ]]; then
        CLIENT_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
    fi
    if [[ -z "$CLIENT_IP" ]]; then
        CLIENT_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.129")
    fi
fi

echo "======================================================"
echo "🧠 ON-DEVICE PI 5 YOLO DETECTOR"
echo "Target:      $PI_HOST"
echo "Model:       $MODEL (running on Pi 5 CPU)"
echo "Feed:        ${WIDTH}x${HEIGHT} @ ${FPS} FPS -> udp://$CLIENT_IP:$PORT"
echo "======================================================"

CONTROL_SOCKET="/tmp/ssh-pi-yolo-$$.sock"
REMOTE_LOG="/tmp/pi-yolo-$$.log"

cleanup() {
    trap - EXIT INT TERM
    echo ""
    echo "Stopping YOLO detector on Pi..."

    if [[ -S "$CONTROL_SOCKET" ]]; then
        ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'pi_yolo_stream.py' || pkill -9 -f 'pi_yolo_stream.py'" 2>/dev/null || true
        ssh -S "$CONTROL_SOCKET" -O exit "$PI_HOST" 2>/dev/null || true
        rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    else
        ssh "$PI_HOST" "pkill -2 -f 'pi_yolo_stream.py' || pkill -9 -f 'pi_yolo_stream.py'" 2>/dev/null || true
    fi

    rm -f "$REMOTE_LOG" 2>/dev/null || true
    echo "Done."
}

trap cleanup EXIT INT TERM

# Connect master SSH
ssh -M -S "$CONTROL_SOCKET" -f -N "$PI_HOST"

# Make sure pi_yolo_stream.py exists on the Pi
scp -S "$CONTROL_SOCKET" pi_yolo_stream.py "$PI_HOST":~/pi_yolo_stream.py >/dev/null 2>&1 || true

# Kill any existing stream processes on the Pi
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'pi_yolo_stream.py|rpicam-vid' 2>/dev/null || true"

# Determine Python binary on the Pi (prefer virtual environment if present)
if ssh -S "$CONTROL_SOCKET" "$PI_HOST" "[ -f ~/helmet_env/bin/python3 ]"; then
    PYTHON_BIN="~/helmet_env/bin/python3"
else
    PYTHON_BIN="python3"
fi

INTERVAL="${INTERVAL:-0.25}"

# Launch YOLO on Pi
REMOTE_CMD="$PYTHON_BIN ~/pi_yolo_stream.py --ip $CLIENT_IP --port $PORT --width $WIDTH --height $HEIGHT --fps $FPS --model $MODEL --interval $INTERVAL"
echo "Starting YOLO inference on $PI_HOST..."
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "$REMOTE_CMD" > "$REMOTE_LOG" 2>&1 &
SSH_PID=$!

sleep 2.0
if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "Error starting YOLO on Pi:"
    cat "$REMOTE_LOG"
    exit 1
fi

# Terminate any leftover local ffplay from previous runs
pkill -f 'ffplay.*8888' 2>/dev/null || true

echo "Launching ffplay viewer (press 'q' to quit)..."
ffplay \
  -an \
  -sn \
  -sync ext \
  -vf "setpts=0" \
  -fflags nobuffer+discardcorrupt \
  -flags low_delay \
  -framedrop \
  -probesize 32 \
  -analyzeduration 0 \
  "udp://0.0.0.0:$PORT?reuse=1&buffer_size=1048576&fifo_size=100000&overrun_nonfatal=1"
