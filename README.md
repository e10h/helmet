# Helmet Pi Camera Stream & YOLO Object Detection

Low-latency video streaming and real-time YOLO object detection for Raspberry Pi 5 (`ethan@pi5.local`) with the IMX708 camera.

---

## 🧠 1. YOLO Detection Running on the Pi (`pi_detect.sh`)

Runs YOLOv8/YOLO11 directly on the Raspberry Pi 5 CPU, draws the detected bounding boxes on the video in real time, and streams the annotated video to your Mac viewer (`ffplay`).

### Pi Setup (One-time)
Because `sudo` requires your password, run this one command in your terminal to install the optimized ARM64 vision libraries on the Pi:

```bash
ssh -t ethan@pi5.local "sudo apt update && sudo apt install -y python3-opencv python3-torch python3-torchvision && pip install --break-system-packages ultralytics"
```

### Run On-Pi YOLO
```bash
./pi_detect.sh
```

---

## ⚡ 2. Zero-Latency Raw Camera Stream (`fast_stream.sh`)

Streams uncompressed raw camera feed at **60 FPS** (~20ms latency) or **120 FPS Turbo mode** (8.3ms frame time) without YOLO processing.

```bash
# 60 FPS Low-Latency
./fast_stream.sh

# 🚀 120 FPS Turbo
./fast_stream.sh --turbo
```

---

## 💻 3. YOLO Detection Running on Mac GPU (`detect.py`)

If you want 120+ FPS detection with zero compute load on the Pi, you can stream raw video from the Pi and run YOLO on your Mac's Apple Silicon Metal GPU (MPS):

```bash
# In terminal 1: start the camera stream
./fast_stream.sh --turbo

# In terminal 2: run Mac GPU YOLO detection & tracking
python3 detect.py --track
```

---

## Stopping Any Stream
Press **`q`** or close the window. The scripts cleanly signal the Pi to release the camera hardware.
