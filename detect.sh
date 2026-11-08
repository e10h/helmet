#!/usr/bin/env bash
set -e

# ==============================================================================
# MAC-SIDE YOLO OBJECT DETECTION + PI STREAM LAUNCHER
# Starts 120 FPS camera on the Pi and runs YOLO on your Mac's GPU in one command.
# ==============================================================================

PI_HOST="${PI_HOST:-ethan@pi5.local}"
PORT="${PORT:-8888}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
FRAMERATE="${FRAMERATE:-120}"
CLIENT_IP="${CLIENT_IP:-}"

# Parse flags
TRACK_FLAG="--track"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-track)
            TRACK_FLAG=""
            shift
            ;;
        -f|--fps)
            FRAMERATE="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

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

# Clean any existing local listener on port 8888
lsof -ti UDP:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
pkill -f "ffplay.*$PORT" 2>/dev/null || true

echo "======================================================"
echo "🎯 HELMET AI: PI STREAM + MAC GPU YOLO"
echo "Target:      $PI_HOST"
echo "Camera:      ${WIDTH}x${HEIGHT} @ ${FRAMERATE} FPS -> udp://$CLIENT_IP:$PORT"
echo "YOLO Device: Apple Silicon GPU (Metal / MPS)"
echo "======================================================"

CONTROL_SOCKET="/tmp/ssh-detect-$$.sock"
REMOTE_LOG="/tmp/detect-stream-$$.log"

cleanup() {
    trap - EXIT INT TERM
    echo ""
    echo "Stopping Pi camera..."

    if [[ -S "$CONTROL_SOCKET" ]]; then
        ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -9 -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
        ssh -S "$CONTROL_SOCKET" -O exit "$PI_HOST" 2>/dev/null || true
        rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    else
        ssh "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -9 -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
    fi

    rm -f "$REMOTE_LOG" 2>/dev/null || true
    echo "Done."
}

trap cleanup EXIT INT TERM

# Connect master SSH
ssh -M -S "$CONTROL_SOCKET" -f -N "$PI_HOST"

# Clean any lingering camera processes on the Pi
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' 2>/dev/null || true"

# Launch rpicam-vid on Pi
RPICAM_CMD="rpicam-vid -n -t 0 \
  --width $WIDTH --height $HEIGHT \
  --framerate $FRAMERATE \
  -b 2500000 \
  --exposure sport \
  --codec libav --libav-format mpegts \
  --profile baseline \
  --libav-video-codec-opts 'preset=ultrafast;tune=zerolatency' \
  --flush \
  --inline \
  -g 12 \
  -o udp://$CLIENT_IP:$PORT"

echo "Starting camera on $PI_HOST..."
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "$RPICAM_CMD" > "$REMOTE_LOG" 2>&1 &
SSH_PID=$!

sleep 0.8
if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "Error starting camera stream on $PI_HOST:"
    cat "$REMOTE_LOG"
    exit 1
fi

echo "Launching Mac GPU YOLO Detector (press 'q' or Esc to quit)..."
python3 detect.py $TRACK_FLAG --url "udp://0.0.0.0:$PORT?reuse=1&buffer_size=1048576&fifo_size=100000&overrun_nonfatal=1"

