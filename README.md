# Helmet Pi Camera Stream

Low-latency and Zero-latency video streaming from a Raspberry Pi 5 (`ethan@pi5.local`) IMX708 camera to your Mac.

---

## ⚡ Zero-Latency Stream (`fast_stream.sh`) - *Recommended*

Engineered for **glass-to-glass latency of ~20-30ms**:
- **60 FPS** default (16.6ms capture interval) or **120 FPS Turbo mode** (8.3ms capture interval).
- **H.264 Baseline profile**: 0 B-frames (eliminates lookahead and frame reordering delay).
- **`preset=ultrafast;tune=zerolatency`**: Sub-millisecond x264 software encode on Pi 5 Cortex-A76 cores.
- **Immediate flushing**: `--flush` and short GOP intervals (`-g 15`) with inline PPS/SPS headers.
- **`ffplay` display tuning**:
  - `-an` / `-sn`: Disables audio and subtitle sync clocks (saving 150-200ms of audio wait buffering).
  - `-sync ext`: Renders to external real-time wall clock.
  - `-vf "setpts=0"`: Strips timestamp pacing delays to render immediately on monitor refresh.
  - `-fflags nobuffer+discardcorrupt` & `-flags low_delay`.

### Usage
```bash
# Standard zero-latency (60 FPS)
./fast_stream.sh

# 🚀 120 FPS Turbo mode (8.3ms per frame!)
./fast_stream.sh --turbo

# Custom resolution or port
./fast_stream.sh -w 1280 -h 720 -f 60 -p 8888
```

---

## 📹 Standard Stream (`stream.sh`)

Standard 30 FPS stream at 640x480.

```bash
./stream.sh
```

---

## Stopping the Stream
Press **`q`** or close the video window; the script sends a clean shutdown signal to the Pi to release the camera sensor.
