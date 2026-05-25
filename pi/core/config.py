# core/config.py -- all SmartGuide Pi settings

# Camera
CAMERA_ENABLED       = False   # flip to True when Pi camera arrives
CAMERA_INDEX         = 0
FRAME_WIDTH          = 640
FRAME_HEIGHT         = 480
FRAME_FPS            = 25

# YOLOv8
YOLO_MODEL_PATH      = 'models/yolov8n_int8.tflite'
YOLO_CONFIDENCE      = 0.50
YOLO_IOU_THRESHOLD   = 0.45
YOLO_INPUT_SIZE      = 640

# Obstacle detection thresholds
DANGER_SCORE_HIGH    = 0.65   # immediate warning
DANGER_SCORE_MEDIUM  = 0.40   # caution
OBSTACLE_COOLDOWN_S  = 2.0    # seconds between same-direction warnings

# WebSocket server
WS_HOST              = '0.0.0.0'
WS_PORT              = 8765

# WiFi hotspot
HOTSPOT_SSID         = 'SmartGuide-Device'
HOTSPOT_PASSWORD     = 'smartguide2025'
HOTSPOT_IP           = '172.18.2.238'

# Visual Lock
VISUAL_LOCK_ENABLED        = False   # flip to True when camera arrives
VISUAL_LOCK_TRIGGER_M      = 50.0    # metres -- start Visual Lock search
VISUAL_LOCK_CONFIRM_FRAMES = 5       # frames monument must be visible

# Audio queue priorities
PRIORITY_CRITICAL    = 0
PRIORITY_OBSTACLE    = 1
PRIORITY_NAVIGATION  = 2
PRIORITY_INFO        = 3
PRIORITY_AMBIENT     = 4
