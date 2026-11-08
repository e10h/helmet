#!/usr/bin/env python3
"""
High-Performance On-Pi YOLO Object Detection with Asynchronous Tracking
Decouples camera streaming from YOLO inference so the video stream NEVER freezes.

- Video Capture & Streaming: runs continuously at full 30 FPS.
- YOLO Inference: runs asynchronously in a background thread at a controlled interval (e.g. 3-5 Hz).
- CPU Throttling: limits PyTorch to 2 cores so the Pi OS & network stack stay responsive.
"""

import os
import sys
import time
import argparse
import subprocess
import threading
import numpy as np

try:
    from picamera2 import Picamera2
except ImportError:
    print("Error: picamera2 not found. Install with: sudo apt install python3-picamera2")
    sys.exit(1)

try:
    import cv2
except ImportError:
    print("Error: OpenCV not found. Install with: sudo apt install python3-opencv")
    sys.exit(1)

try:
    import torch
    # Restrict PyTorch CPU threads so it never starves the Pi's OS or Wi-Fi stack
    torch.set_num_threads(2)
    from ultralytics import YOLO
except ImportError:
    print("Error: ultralytics or torch not found.")
    sys.exit(1)


class AsyncYOLODetector(threading.Thread):
    def __init__(self, model_name="yolov8n.pt", conf=0.35, interval=0.25):
        """
        Runs YOLO in background thread.
        interval: minimum seconds between detections (default 0.25s = 4 detections/sec)
        """
        super().__init__(daemon=True)
        self.model = YOLO(model_name)
        self.conf = conf
        self.interval = interval
        self.lock = threading.Lock()
        self.latest_frame = None
        self.boxes = []
        self.infer_ms = 0.0
        self.running = True
        self.new_frame_event = threading.Event()

    def update_frame(self, frame):
        with self.lock:
            self.latest_frame = frame
        self.new_frame_event.set()

    def get_detections(self):
        with self.lock:
            return list(self.boxes), self.infer_ms

    def run(self):
        last_run = 0.0
        while self.running:
            self.new_frame_event.wait(timeout=0.1)
            self.new_frame_event.clear()

            now = time.time()
            if (now - last_run) < self.interval:
                time.sleep(0.01)
                continue

            with self.lock:
                frame = self.latest_frame
            if frame is None:
                continue

            start_t = time.time()
            try:
                # Downscale frame for even faster inference if needed
                results = self.model(frame, conf=self.conf, verbose=False)
                t_infer = (time.time() - start_t) * 1000.0

                current_boxes = []
                if results and len(results) > 0 and results[0].boxes is not None:
                    for b in results[0].boxes:
                        cls_id = int(b.cls[0])
                        conf_score = float(b.conf[0])
                        xyxy = b.xyxy[0].cpu().numpy().astype(int)
                        label = f"{self.model.names[cls_id]} {int(conf_score * 100)}%"
                        current_boxes.append((xyxy, label, cls_id))

                with self.lock:
                    self.boxes = current_boxes
                    self.infer_ms = t_infer
                last_run = time.time()

            except Exception as e:
                print(f"Inference error: {e}")
                time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description="Smooth Asynchronous On-Pi YOLO Streaming")
    parser.add_argument("--ip", default="192.168.1.129", help="Destination Mac IP")
    parser.add_argument("--port", type=int, default=8888, help="Destination UDP port")
    parser.add_argument("--width", type=int, default=640, help="Width (default: 640)")
    parser.add_argument("--height", type=int, default=480, help="Height (default: 480)")
    parser.add_argument("--fps", type=int, default=30, help="Video stream FPS (default: 30)")
    # Default to high-speed ARM NEON NCNN model if available
    default_model = "yolo11n_ncnn_model" if os.path.exists("yolo11n_ncnn_model") or os.path.exists(os.path.expanduser("~/yolo11n_ncnn_model")) else "yolov8n.pt"

    parser.add_argument("--model", default=default_model, help="YOLO model or NCNN directory")
    parser.add_argument("--imgsz", type=int, default=320, help="Inference image size (default: 320 for high FPS)")
    parser.add_argument("--conf", type=float, default=0.35, help="Confidence threshold")
    parser.add_argument("--interval", type=float, default=0.25,
                        help="YOLO detection interval in seconds (default: 0.25 = 4 detections/sec)")
    args = parser.parse_args()

    print("=" * 55)
    print("🚀 ASYNC HELMET YOLO DETECTOR & STREAMER")
    print(f"Model:       {args.model} (capped at 2 CPU cores)")
    print(f"Video Feed:  {args.width}x{args.height} @ {args.fps} FPS")
    print(f"YOLO Rate:   Every {args.interval}s (~{int(1/args.interval)} Hz)")
    print(f"Streaming:   udp://{args.ip}:{args.port}")
    print("=" * 55)

    # Initialize asynchronous YOLO worker
    print("Loading YOLO in background worker thread...")
    yolo_worker = AsyncYOLODetector(model_name=args.model, conf=args.conf, interval=args.interval)
    yolo_worker.start()

    # Initialize Picamera2
    print("Initializing Picamera2...")
    picam2 = Picamera2()
    camera_config = picam2.create_video_configuration(
        main={"size": (args.width, args.height), "format": "RGB888"},
        controls={"FrameRate": args.fps}
    )
    picam2.configure(camera_config)
    picam2.start()
    time.sleep(0.8)

    # Launch FFmpeg output pipeline
    ffmpeg_cmd = [
        "ffmpeg",
        "-y",
        "-f", "rawvideo",
        "-vcodec", "rawvideo",
        "-pix_fmt", "bgr24",
        "-s", f"{args.width}x{args.height}",
        "-r", str(args.fps),
        "-i", "-",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-preset", "ultrafast",
        "-tune", "zerolatency",
        "-profile:v", "baseline",
        "-g", "15",
        "-b:v", "2000k",
        "-f", "mpegts",
        f"udp://{args.ip}:{args.port}?pkt_size=1316"
    ]
    ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)

    prev_time = time.time()
    fps_smooth = 0.0

    print("Stream running smoothly! Press Ctrl+C to stop.")

    try:
        while True:
            # 1. Capture camera frame (30 FPS non-blocking)
            frame_rgb = picam2.capture_array()
            frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)

            # 2. Hand off frame to background YOLO worker (non-blocking)
            yolo_worker.update_frame(frame_bgr)

            # 3. Get latest detected bounding boxes (non-blocking)
            boxes, infer_ms = yolo_worker.get_detections()

            # 4. Draw persistent bounding boxes onto the live video frame
            for xyxy, label, cls_id in boxes:
                x1, y1, x2, y2 = xyxy
                cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(
                    frame_bgr,
                    label,
                    (x1, max(y1 - 6, 16)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    (0, 255, 0),
                    1,
                    cv2.LINE_AA
                )

            # Calculate live streaming FPS
            curr_time = time.time()
            fps = 1.0 / (curr_time - prev_time) if (curr_time - prev_time) > 0 else 0
            prev_time = curr_time
            fps_smooth = 0.9 * fps_smooth + 0.1 * fps if fps_smooth > 0 else fps

            # Draw HUD bar
            hud_text = f"STREAM: {fps_smooth:.1f} FPS | YOLO: {infer_ms:.0f}ms | Dets: {len(boxes)}"
            cv2.rectangle(frame_bgr, (5, 5), (5 + len(hud_text) * 11, 30), (0, 0, 0), -1)
            cv2.putText(frame_bgr, hud_text, (10, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA)

            # 5. Pipe frame immediately to FFmpeg UDP streamer
            try:
                ffmpeg_proc.stdin.write(frame_bgr.tobytes())
            except BrokenPipeError:
                break

    except KeyboardInterrupt:
        print("\nStopping stream...")
    finally:
        yolo_worker.running = False
        picam2.stop()
        if ffmpeg_proc.stdin:
            ffmpeg_proc.stdin.close()
        ffmpeg_proc.wait()
        print("Shutdown complete.")


if __name__ == "__main__":
    main()
