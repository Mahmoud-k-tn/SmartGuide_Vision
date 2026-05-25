# vision/obstacle_tracker.py
# YOLOv8 Nano TFLite INT8 obstacle detection at 25 FPS.
# Falls back to MockObstacleGenerator when no camera/model.
 
import asyncio
import random
import time
import numpy as np
from core.config import (
    CAMERA_ENABLED, YOLO_MODEL_PATH, YOLO_CONFIDENCE,
    DANGER_SCORE_HIGH, DANGER_SCORE_MEDIUM, OBSTACLE_COOLDOWN_S,
    FRAME_WIDTH, FRAME_HEIGHT,
)
from core.websocket_server import broadcast
 
DIRECTIONS = ['ahead', 'left', 'right']
_last_alert = {}
 
 
class ObstacleTracker:
    def __init__(self):
        self._model = None
        self._use_mock = not CAMERA_ENABLED
 
        if CAMERA_ENABLED:
            try:
                import tflite_runtime.interpreter as tflite
                self._model = tflite.Interpreter(model_path=YOLO_MODEL_PATH)
                self._model.allocate_tensors()
                print('[Obstacle] YOLOv8 TFLite model loaded.')
            except Exception as e:
                print('[Obstacle] Model load failed: ' + str(e) + ' -- using mock')
                self._use_mock = True
        else:
            print('[Obstacle] CAMERA_ENABLED=False -- using MockObstacleGenerator')
 
    async def run(self, camera):
        """Main loop -- read frames, detect obstacles, broadcast to phone."""
        if self._use_mock:
            await MockObstacleGenerator().run()
            return
 
        print('[Obstacle] Starting real detection loop...')
        while True:
            ret, frame = camera.read()
            if not ret:
                await asyncio.sleep(0.04)
                continue
            detections = self._detect(frame)
            await self._process(detections)
            await asyncio.sleep(1.0 / 25.0)
 
 
    def _detect(self, frame):
        """Run YOLOv8 TFLite inference. Returns list of detections."""
        try:
            import cv2
            input_details  = self._model.get_input_details()
            output_details = self._model.get_output_details()
            resized = cv2.resize(frame, (640, 640))
            inp = resized.astype(np.uint8)[np.newaxis]
            self._model.set_tensor(input_details[0]['index'], inp)
            self._model.invoke()
            output = self._model.get_tensor(output_details[0]['index'])
            return self._parse_output(output, frame.shape)
        except Exception as e:
            print('[Obstacle] Inference error: ' + str(e))
            return []
 
    def _parse_output(self, output, frame_shape):
        """Parse YOLOv8 output tensor into detection dicts."""
        detections = []
        h, w = frame_shape[:2]
        preds = output[0].T
        for pred in preds:
            scores  = pred[4:]
            conf    = float(np.max(scores))
            cls_id  = int(np.argmax(scores))
            if conf < YOLO_CONFIDENCE:
                continue
            cx, cy, bw, bh = pred[:4]
            x1 = int((cx - bw / 2) * w / 640)
            y1 = int((cy - bh / 2) * h / 640)
            x2 = int((cx + bw / 2) * w / 640)
            y2 = int((cy + bh / 2) * h / 640)
            box_h      = y2 - y1
            distance_m = max(0.5, round(200.0 / (box_h + 1e-5), 1))
            cx_norm = (x1 + x2) / 2.0 / w
            if cx_norm < 0.35:
                direction = 'left'
            elif cx_norm > 0.65:
                direction = 'right'
            else:
                direction = 'ahead'
            detections.append({
                'class_id':   cls_id,
                'confidence': conf,
                'direction':  direction,
                'distance_m': distance_m,
            })
        return detections
 

    async def _process(self, detections):
        """Broadcast obstacle warnings to phone."""
        now = time.time()
        for det in detections:
            score     = det['confidence']
            direction = det['direction']
            dist      = det['distance_m']
            if now - _last_alert.get(direction, 0) < OBSTACLE_COOLDOWN_S:
                continue
            if score >= DANGER_SCORE_HIGH:
                _last_alert[direction] = now
                await broadcast({
                    'type':       'obstacle_warning',
                    'direction':  direction,
                    'distance_m': dist,
                    'severity':   'high',
                })
                print('[Obstacle] HIGH: ' + direction + ' ' + str(dist) + 'm')
            elif score >= DANGER_SCORE_MEDIUM:
                _last_alert[direction] = now
                await broadcast({
                    'type':       'obstacle_warning',
                    'direction':  direction,
                    'distance_m': dist,
                    'severity':   'medium',
                })
                print('[Obstacle] MEDIUM: ' + direction + ' ' + str(dist) + 'm')
 
 
class MockObstacleGenerator:
    """Generates fake obstacle events for testing without hardware."""
 
    async def run(self):
        print('[Mock] Obstacle generator running...')
        while True:
            await asyncio.sleep(random.uniform(13, 17))
            direction  = random.choice(DIRECTIONS)
            distance_m = round(random.uniform(0.5, 3.0), 1)
            severity   = random.choice(['high', 'medium'])
            await broadcast({
                'type':       'obstacle_warning',
                'direction':  direction,
                'distance_m': distance_m,
                'severity':   severity,
            })
            print('[Mock] Obstacle ' + severity + ': ' + direction + ' ' + str(distance_m) + 'm')
            await asyncio.sleep(3)
            await broadcast({
                'type':      'obstacle_clear',
                'direction': direction,
            })
            print('[Mock] Clear: ' + direction)
 
