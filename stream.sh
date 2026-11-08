#!/usr/bin/env bash
set -e

# Defaults
PI_HOST="${PI_HOST:-ethan@pi5.local}"
PORT="${PORT:-8888}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
FRAMERATE="${FRAMERATE:-30}"
CLIENT_IP="${CLIENT_IP:-}"

# Parse optional command-line flags
show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Stream video from Raspberry Pi camera to ffplay with low latency.

Options:
  -t, --target <user@host>  SSH target (default: ethan@pi5.local)
  -i, --ip <address>        Local IP to receive the UDP stream (auto-detected if omitted)
  -p, --port <port>         UDP port to use (default: 8888)
  -w, --width <pixels>      Camera capture width (default: 640)
  -h, --height <pixels>     Camera capture height (default: 480)
  -f, --fps <rate>          Framerate in FPS (default: 30)
  --help                    Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            PI_HOST="$2"
            shift 2
            ;;
        -i|--ip)
            CLIENT_IP="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -w|--width)
            WIDTH="$2"
            shift 2
            ;;
        -h|--height)
            HEIGHT="$2"
            shift 2
            ;;
        -f|--fps)
            FRAMERATE="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Ensure ffplay is available locally
if ! command -v ffplay &>/dev/null; then
    echo "Error: ffplay is not installed or not in PATH."
    echo "You can install it with: brew install ffmpeg"
    exit 1
fi

# Detect local IP if not explicitly set
if [[ -z "$CLIENT_IP" ]]; then
    # Extract hostname from PI_HOST for routing check
    TARGET_NAME="${PI_HOST#*@}"
    
    # 1. Check network route towards target
    IFACE=$(route get "$TARGET_NAME" 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$IFACE" ]]; then
        CLIENT_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
    fi

    # 2. Try en0
    if [[ -z "$CLIENT_IP" ]]; then
        CLIENT_IP=$(ipconfig getifaddr en0 2>/dev/null || true)
    fi

    # 3. Fallback to 192.168.1.129
    if [[ -z "$CLIENT_IP" ]]; then
        CLIENT_IP="192.168.1.129"
    fi
fi

echo "=========================================="
echo "Raspberry Pi Low-Latency Camera Stream"
echo "Target:      $PI_HOST"
echo "Receiver:    udp://$CLIENT_IP:$PORT"
echo "Format:      ${WIDTH}x${HEIGHT} @ ${FRAMERATE}fps (MPEG-TS)"
echo "=========================================="

CONTROL_SOCKET="/tmp/ssh-stream-$$.sock"
REMOTE_LOG="/tmp/rpicam-vid-$$.log"

cleanup() {
    # Disable trap to avoid recursive calls
    trap - EXIT INT TERM
    echo ""
    echo "Stopping camera stream and viewer..."

    if [[ -n "${FFPLAY_PID:-}" ]] && kill -0 "$FFPLAY_PID" 2>/dev/null; then
        kill "$FFPLAY_PID" 2>/dev/null || true
    fi

    if [[ -S "$CONTROL_SOCKET" ]]; then
        # Send SIGINT first to allow libcamera/rpicam-vid to cleanly release sensor
        ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
        ssh -S "$CONTROL_SOCKET" -O exit "$PI_HOST" 2>/dev/null || true
        rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    else
        ssh "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
    fi

    rm -f "$REMOTE_LOG" 2>/dev/null || true
    echo "Stream terminated cleanly."
}

trap cleanup EXIT INT TERM

# Establish master SSH connection (reuses connection and prompts for password only once if keys aren't set)
echo "Connecting to $PI_HOST..."
ssh -M -S "$CONTROL_SOCKET" -f -N "$PI_HOST"

# Clean up any previously orphaned rpicam-vid instance on the Pi
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' 2>/dev/null || true"

# Launch rpicam-vid on Raspberry Pi in background
RPICAM_CMD="rpicam-vid -n -t 0 --width $WIDTH --height $HEIGHT --framerate $FRAMERATE --codec libav --libav-format mpegts --low-latency -o udp://$CLIENT_IP:$PORT"
echo "Launching rpicam-vid on $PI_HOST..."
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "$RPICAM_CMD" > "$REMOTE_LOG" 2>&1 &
SSH_STREAM_PID=$!

# Brief check to ensure rpicam-vid didn't exit immediately due to error (e.g. camera missing)
sleep 0.8
if ! kill -0 "$SSH_STREAM_PID" 2>/dev/null; then
    echo "Error: rpicam-vid failed to start on $PI_HOST."
    if [[ -s "$REMOTE_LOG" ]]; then
        echo "Remote log output:"
        cat "$REMOTE_LOG"
    fi
    exit 1
fi

echo "Starting local ffplay viewer (close window or press 'q' to quit)..."
ffplay -fflags nobuffer -flags low_delay -framedrop -analyzeduration 0 -probesize 32 "udp://0.0.0.0:$PORT?fifo_size=0"


