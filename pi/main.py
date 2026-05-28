# main.py -- SmartGuide Pi entry point (Phase 1)

import asyncio
from core.websocket_server   import start_server
from vision.camera           import Camera
from vision.obstacle_tracker import ObstacleTracker
from hmi.audio_queue         import AudioQueue


async def main():
    print('SmartGuide Vision -- Pi Phase 1')
    print('================================')

    camera  = Camera()
    tracker = ObstacleTracker()
    audio   = AudioQueue()

    await asyncio.gather(
        start_server(),
        tracker.run(camera),
        audio.run(),
    )


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print('[Main] Stopped.')
