#!/usr/bin/env python3
"""
Real-time Helmet Camera Object Detection & Tracking with YOLO
Connects to the low-latency UDP stream from Raspberry Pi and runs YOLO on Apple Silicon.
"""

import sys
import time
import argparse
import threading
import cv2
import torch
from ultralytics import YOLO


class RealtimeUDPStream:
    """
    Threaded capture to prevent OpenCV internal buffer lag.
    Guarantees the main loop always processes the latest live frame.
    """
    def __init__(self, url):
        self.url = url
        self.cap = cv2.VideoCapture(self.url, cv2.CAP_FFMPEG)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.lock = threading.Lock()
        self.frame = None
        self.running = True
        self.connected = False
        self.fail_count = 0

        self.thread = threading.Thread(target=self._update, daemon=True)
        self.thread.start()

    def _update(self):
        while self.running:
            if not self.cap.isOpened():
                time.sleep(1.0)
                self.cap.open(self.url, cv2.CAP_FFMPEG)
                if not self.cap.isOpened():
                    self.fail_count += 1
                    if self.fail_count % 5 == 1:
                        print("Waiting for port/stream... (if another viewer or ffplay is open, close it)")
                continue

            self.fail_count = 0
            ret, frame = self.cap.read()
            if ret and frame is not None:
                with self.lock:
                    self.frame = frame
                    self.connected = True
            else:
                time.sleep(0.005)

    def read(self):
        with self.lock:
            if self.frame is not None:
                return True, self.frame.copy()
            return False, None

    def release(self):
        self.running = False
        if self.cap.isOpened():
            self.cap.release()


def main():
    parser = argparse.ArgumentParser(description="Real-time YOLO Object Detection for Helmet Camera")
    parser.add_argument("--url", default="udp://0.0.0.0:8888?reuse=1&buffer_size=1048576&fifo_size=100000&overrun_nonfatal=1",
                        help="UDP stream URL (default: udp://0.0.0.0:8888?...)")
    parser.add_argument("--model", default="yolo11n.pt", help="YOLO model (default: yolo11n.pt or yolov8n.pt)")
    parser.add_argument("--conf", type=float, default=0.35, help="Confidence threshold (default: 0.35)")
    parser.add_argument("--track", action="store_true", help="Enable persistent object tracking IDs")
    parser.add_argument("--classes", nargs="+", type=int, default=None,
                        help="Filter class IDs (e.g., 0 for person, 2 for car, 1 for bicycle)")
    parser.add_argument("--device", default=None, help="Device ('mps', 'cuda', 'cpu')")
    args = parser.parse_args()

    # Determine optimal compute device (Apple Silicon GPU via MPS)
    if args.device:
        device = args.device
    elif torch.backends.mps.is_available():
        device = "mps"
    elif torch.cuda.is_available():
        device = "cuda"
    else:
        device = "cpu"

    print("=" * 55)
    print("🎯 HELMET CAMERA YOLO OBJECT DETECTION")
    print(f"Model:       {args.model}")
    print(f"Device:      {device} ({'Apple Silicon Metal GPU' if device == 'mps' else device})")
    print(f"Stream:      {args.url}")
    print(f"Tracking:    {'Enabled' if args.track else 'Disabled'}")
    print("Controls:    [q / Esc] Quit  |  [t] Toggle Tracking  |  [s] Snapshot")
    print("=" * 55)

    print("Loading YOLO model...")
    model = YOLO(args.model)
    # Warmup
    try:
        model(torch.zeros(1, 3, 480, 640).to(device), device=device)
    except Exception:
        pass

    print("Connecting to live video stream...")
    stream = RealtimeUDPStream(args.url)

    tracking_enabled = args.track
    prev_time = time.time()
    fps_smooth = 0.0

    cv2.namedWindow("Helmet Cam - YOLO AI", cv2.WINDOW_NORMAL)

    try:
        # Wait for first frame
        while True:
            ret, frame = stream.read()
            if ret:
                break
            time.sleep(0.05)
            # Check window close
            if cv2.getWindowProperty("Helmet Cam - YOLO AI", cv2.WND_PROP_VISIBLE) < 1:
                return

        print("Stream connected! Running real-time inference...")

        while True:
            ret, frame = stream.read()
            if not ret or frame is None:
                time.sleep(0.005)
                continue

            start_infer = time.time()

            # Run YOLO Detection or Tracking
            if tracking_enabled:
                results = model.track(
                    frame,
                    persist=True,
                    device=device,
                    conf=args.conf,
                    classes=args.classes,
                    verbose=False
                )
            else:
                results = model(
                    frame,
                    device=device,
                    conf=args.conf,
                    classes=args.classes,
                    verbose=False
                )

            infer_ms = (time.time() - start_infer) * 1000.0

            # Render bounding boxes onto frame
            annotated_frame = results[0].plot()

            # Calculate FPS
            curr_time = time.time()
            fps = 1.0 / (curr_time - prev_time) if (curr_time - prev_time) > 0 else 0
            prev_time = curr_time
            fps_smooth = 0.9 * fps_smooth + 0.1 * fps if fps_smooth > 0 else fps

            # Draw HUD Overlay
            num_dets = len(results[0].boxes) if results[0].boxes is not None else 0
            hud_text = f"FPS: {fps_smooth:.1f} | Infer: {infer_ms:.1f}ms | Detections: {num_dets} | Dev: {device.upper()}"
            if tracking_enabled:
                hud_text += " [TRACKING]"

            cv2.rectangle(annotated_frame, (10, 10), (10 + len(hud_text) * 11, 40), (0, 0, 0), -1)
            cv2.putText(
                annotated_frame,
                hud_text,
                (15, 32),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.55,
                (0, 255, 0),
                2,
                cv2.LINE_AA
            )

            cv2.imshow("Helmet Cam - YOLO AI", annotated_frame)

            key = cv2.waitKey(1) & 0xFF
            if key == ord('q') or key == 27:  # 'q' or ESC
                break
            elif key == ord('t'):
                tracking_enabled = not tracking_enabled
                print(f"Tracking {'ENABLED' if tracking_enabled else 'DISABLED'}")
            elif key == ord('s'):
                snap_name = f"snapshot_{int(time.time())}.jpg"
                cv2.imwrite(snap_name, annotated_frame)
                print(f"Saved snapshot to {snap_name}")

    finally:
        stream.release()
        cv2.destroyAllWindows()
        print("Viewer closed.")


if __name__ == "__main__":
    main()

