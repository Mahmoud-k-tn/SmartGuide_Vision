# vision/camera.py -- camera interface, falls back to mock when no hardware

import numpy as np
from core.config import CAMERA_ENABLED, CAMERA_INDEX, FRAME_WIDTH, FRAME_HEIGHT


class Camera:
    def __init__(self):
        self._cap = None
        self._mock = not CAMERA_ENABLED

        if CAMERA_ENABLED:
            try:
                import cv2
                self._cap = cv2.VideoCapture(CAMERA_INDEX)
                if not self._cap.isOpened():
                    print('[Camera] Hardware camera failed -- falling back to mock')
                    self._mock = True
                else:
                    self._cap.set(cv2.CAP_PROP_FRAME_WIDTH,  FRAME_WIDTH)
                    self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_HEIGHT)
                    print('[Camera] Hardware camera opened.')
            except Exception as e:
                print('[Camera] Error: ' + str(e) + ' -- falling back to mock')
                self._mock = True
        else:
            print('[Camera] CAMERA_ENABLED=False -- using mock frames')

    def read(self):
        """Return (success, frame). Frame is (H, W, 3) uint8 BGR."""
        if self._mock:
            frame = np.random.randint(0, 255,
                    (FRAME_HEIGHT, FRAME_WIDTH, 3), dtype=np.uint8)
            return True, frame

        import cv2
        ret, frame = self._cap.read()
        if not ret:
            print('[Camera] Frame read failed.')
        return ret, frame

    def release(self):
        if self._cap is not None:
            self._cap.release()
            print('[Camera] Released.')
