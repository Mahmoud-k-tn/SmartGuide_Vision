# hmi/audio_queue.py -- priority audio queue P0-P4
# P0 = critical, P4 = ambient

import asyncio
import heapq
from core.config import PRIORITY_INFO


class AudioItem:
    def __init__(self, priority, text):
        self.priority = priority
        self.text     = text

    def __lt__(self, other):
        return self.priority < other.priority


class AudioQueue:
    def __init__(self):
        self._heap = []
        self._lock = asyncio.Lock()

    async def enqueue(self, text, priority=PRIORITY_INFO):
        async with self._lock:
            heapq.heappush(self._heap, AudioItem(priority, text))

    async def dequeue(self):
        async with self._lock:
            if self._heap:
                return heapq.heappop(self._heap)
        return None

    async def run(self):
        """Process queue -- prints for now, add espeak for Pi speaker."""
        print('[Audio] Queue running.')
        while True:
            item = await self.dequeue()
            if item:
                print('[Audio P' + str(item.priority) + '] ' + item.text)
                # TODO: subprocess.run(['espeak', item.text]) for Pi speaker
            await asyncio.sleep(0.1)
