#!/usr/bin/env bash
set -e

# ==============================================================================
# ZERO LATENCY STREAM (Raspberry Pi 5 -> Mac)
# Engineered for absolute minimum glass-to-glass delay (~20-30ms)
# ==============================================================================

# Defaults
PI_HOST="${PI_HOST:-ethan@pi5.local}"
PORT="${PORT:-8888}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
FRAMERATE="${FRAMERATE:-60}"   # 60 FPS default = 16.6ms frame time
EXPOSURE="${EXPOSURE:-sport}"  # Short shutter time reduces sensor integration latency
BITRATE="${BITRATE:-2500000}"  # 2.5 Mbps cap prevents Wi-Fi packet burst drops
GOP="${GOP:-}"
TURBO_MODE=0

show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Ultra-low-latency video streaming from Raspberry Pi camera to Mac.

Options:
  --turbo, -u               Enable 120 FPS Turbo mode (8.3ms frame time!)
  -f, --fps <rate>          Framerate (default: 60)
  -b, --bitrate <bps>       Target bitrate (default: 2500000 / 2.5 Mbps)
  -g, --gop <frames>        Keyframe interval in frames (default: 12 in turbo, 15 in 60fps)
  -w, --width <pixels>      Camera capture width (default: 640)
  -h, --height <pixels>     Camera capture height (default: 480)
  -p, --port <port>         UDP port (default: 8888)
  -t, --target <user@host>  SSH target (default: ethan@pi5.local)
  -i, --ip <address>        Receiver IP (auto-detected if omitted)
  --help                    Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --turbo|-u)
            TURBO_MODE=1
            FRAMERATE=120
            shift
            ;;
        -b|--bitrate)
            BITRATE="$2"
            shift 2
            ;;
        -g|--gop)
            GOP="$2"
            shift 2
            ;;
        -f|--fps)
            FRAMERATE="$2"
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
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -t|--target)
            PI_HOST="$2"
            shift 2
            ;;
        -i|--ip)
            CLIENT_IP="$2"
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
    exit 1
fi

# Auto-detect client IP
if [[ -z "${CLIENT_IP:-}" ]]; then
    TARGET_NAME="${PI_HOST#*@}"
    IFACE=$(route get "$TARGET_NAME" 2>/dev/null | awk '/interface:/{print $2}')
    if [[ -n "$IFACE" ]]; then
        CLIENT_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
    fi
    if [[ -z "$CLIENT_IP" ]]; then
        CLIENT_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.129")
    fi
fi

# Calculate optimal intra-frame GOP if not overridden:
# A shorter GOP (10-15 frames = ~100ms in turbo) instantly clears any Wi-Fi packet-loss
# compression smear / datamosh artifacts without waiting.
if [[ -z "$GOP" ]]; then
    if [[ "$TURBO_MODE" -eq 1 || "$FRAMERATE" -ge 90 ]]; then
        GOP=12   # ~100ms at 120 FPS
    else
        GOP=15   # ~250ms at 60 FPS
    fi
fi

echo "======================================================"
echo "⚡ ZERO-LATENCY HELMET STREAM"
echo "Target:      $PI_HOST"
echo "Receiver:    udp://$CLIENT_IP:$PORT"
echo "Video:       ${WIDTH}x${HEIGHT} @ ${FRAMERATE} FPS (Keyframe interval: every $GOP frames)"
echo "Bitrate:     $(( BITRATE / 1000000 )) Mbps (burst-capped)"
echo "Tuning:      x264 ultrafast + zerolatency (Baseline, 0 B-frames)"
echo "Anti-Mosh:   Rapid keyframes + 1MB socket buffer"
echo "======================================================"

CONTROL_SOCKET="/tmp/ssh-fast-$$.sock"
REMOTE_LOG="/tmp/rpicam-fast-$$.log"

cleanup() {
    trap - EXIT INT TERM
    echo ""
    echo "Stopping stream..."

    if [[ -n "${FFPLAY_PID:-}" ]] && kill -0 "$FFPLAY_PID" 2>/dev/null; then
        kill "$FFPLAY_PID" 2>/dev/null || true
    fi

    if [[ -S "$CONTROL_SOCKET" ]]; then
        ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -9 -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
        ssh -S "$CONTROL_SOCKET" -O exit "$PI_HOST" 2>/dev/null || true
        rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    else
        ssh "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' || pkill -9 -f 'rpicam-vid.*$PORT'" 2>/dev/null || true
    fi

    rm -f "$REMOTE_LOG" 2>/dev/null || true
    echo "Clean exit."
}

trap cleanup EXIT INT TERM

# Establish master SSH connection
ssh -M -S "$CONTROL_SOCKET" -f -N "$PI_HOST"

# Clean any existing camera processes
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "pkill -2 -f 'rpicam-vid.*$PORT' 2>/dev/null || true"

# Launch rpicam-vid with maximum speed / zero-latency pipeline
RPICAM_CMD="rpicam-vid -n -t 0 \
  --width $WIDTH --height $HEIGHT \
  --framerate $FRAMERATE \
  -b $BITRATE \
  --exposure $EXPOSURE \
  --codec libav --libav-format mpegts \
  --profile baseline \
  --libav-video-codec-opts 'preset=ultrafast;tune=zerolatency' \
  --flush \
  --inline \
  -g $GOP \
  -o udp://$CLIENT_IP:$PORT"

echo "Streaming from camera..."
ssh -S "$CONTROL_SOCKET" "$PI_HOST" "$RPICAM_CMD" > "$REMOTE_LOG" 2>&1 &
SSH_PID=$!

sleep 0.6
if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "Error starting camera stream on $PI_HOST:"
    cat "$REMOTE_LOG"
    exit 1
fi

echo "Launching zero-latency ffplay viewer (press 'q' to quit)..."
# -an: disable audio (prevents audio-clock sync lag)
# -sn: disable subtitles
# -sync ext: sync to external wall clock (render instantly upon arrival)
# -vf "setpts=0": remove presentation timestamp buffer pacing
# -fflags nobuffer+discardcorrupt: disable libavformat buffering
# -flags low_delay: disable decoder lookahead
# -flags2 +fast: enable fast/aggressive decoding
# -framedrop: drop behind-schedule frames
# -probesize 32 -analyzeduration 0: instant start
# buffer_size=1048576: 1MB OS socket buffer absorbs Wi-Fi burst jitter without dropping packets
# fifo_size=100000: small FIFO buffer to prevent datamosh packet loss
ffplay \
  -an \
  -sn \
  -sync ext \
  -vf "setpts=0" \
  -fflags nobuffer+discardcorrupt \
  -flags low_delay \
  -flags2 +fast \
  -framedrop \
  -probesize 32 \
  -analyzeduration 0 \
  "udp://0.0.0.0:$PORT?buffer_size=1048576&fifo_size=100000&overrun_nonfatal=1"


