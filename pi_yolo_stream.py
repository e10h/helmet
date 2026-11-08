#!/usr/bin/env python3
"""
Runs YOLO Object Detection directly on Raspberry Pi 5.
Captures frames using Picamera2, performs YOLO inference,
overlays bounding boxes, and streams the annotated video over UDP to the Mac.
"""

import sys
import time
import argparse
import subprocess
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
    from ultralytics import YOLO
except ImportError:
    print("Error: ultralytics not found. Install with: pip install ultralytics")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Pi-Side YOLO Object Detection and Streaming")
    parser.add_argument("--ip", default="192.168.1.129", help="Destination IP address (Mac)")
    parser.add_argument("--port", type=int, default=8888, help="Destination UDP port")
    parser.add_argument("--width", type=int, default=640, help="Camera width (default: 640)")
    parser.add_argument("--height", type=int, default=480, help="Camera height (default: 480)")
    parser.add_argument("--fps", type=int, default=30, help="Camera framerate (default: 30)")
    parser.add_argument("--model", default="yolov8n.pt", help="YOLO model (default: yolov8n.pt or yolo11n.pt)")
    parser.add_argument("--conf", type=float, default=0.35, help="Confidence threshold")
    parser.add_argument("--skip-frames", type=int, default=1,
                        help="Run YOLO every N frames to maintain high video framerate (default: 1 = every frame)")
    args = parser.parse_args()

    print("=" * 50)
    print("🧠 RASPBERRY PI ON-DEVICE YOLO DETECTOR")
    print(f"Model:       {args.model}")
    print(f"Camera:      {args.width}x{args.height} @ {args.fps} FPS")
    print(f"Streaming:   udp://{args.ip}:{args.port}")
    print("=" * 50)

    # Load YOLO on Pi CPU
    print(f"Loading YOLO model ({args.model}) on Pi CPU...")
    model = YOLO(args.model)

    # Initialize Picamera2
    print("Initializing Picamera2...")
    picam2 = Picamera2()
    camera_config = picam2.create_video_configuration(
        main={"size": (args.width, args.height), "format": "RGB888"},
        controls={"FrameRate": args.fps}
    )
    picam2.configure(camera_config)
    picam2.start()
    time.sleep(1.0)  # Allow sensor exposure to stabilize

    # Launch FFmpeg to stream annotated frames over UDP
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
    print(f"Starting UDP stream pipeline -> udp://{args.ip}:{args.port}")
    ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    frame_count = 0
    prev_time = time.time()
    fps_smooth = 0.0
    last_boxes = []

    print("Running detection and streaming. Press Ctrl+C to stop.")

    try:
        while True:
            # Capture frame from Pi camera (RGB format)
            frame_rgb = picam2.capture_array()
            # Convert RGB to BGR for OpenCV
            frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)

            frame_count += 1
            run_yolo = (frame_count % args.skip_frames == 0)

            start_infer = time.time()
            if run_yolo:
                results = model(frame_bgr, conf=args.conf, verbose=False)
                annotated_frame = results[0].plot()
                infer_ms = (time.time() - start_infer) * 1000.0

                # Log detections to terminal
                boxes = results[0].boxes
                if boxes is not None and len(boxes) > 0:
                    names = [model.names[int(cls)] for cls in boxes.cls]
                    print(f"[{time.strftime('%H:%M:%S')}] Detected ({infer_ms:.0f}ms): {', '.join(names)}")
            else:
                annotated_frame = frame_bgr
                infer_ms = 0.0

            # Calculate FPS
            curr_time = time.time()
            fps = 1.0 / (curr_time - prev_time) if (curr_time - prev_time) > 0 else 0
            prev_time = curr_time
            fps_smooth = 0.9 * fps_smooth + 0.1 * fps if fps_smooth > 0 else fps

            # Draw HUD stats on the video
            hud_text = f"PI 5 YOLO | FPS: {fps_smooth:.1f} | Infer: {infer_ms:.0f}ms"
            cv2.putText(annotated_frame, hud_text, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

            # Pipe annotated BGR frame to FFmpeg UDP streamer
            try:
                ffmpeg_proc.stdin.write(annotated_frame.tobytes())
            except BrokenPipeError:
                err = ffmpeg_proc.stderr.read().decode('utf-8', errors='ignore') if ffmpeg_proc.stderr else ""
                print(f"FFmpeg pipeline broken: {err}")
                break

    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        picam2.stop()
        if ffmpeg_proc.stdin:
            ffmpeg_proc.stdin.close()
        ffmpeg_proc.wait()
        print("Pipeline stopped.")


if __name__ == "__main__":
    main()

