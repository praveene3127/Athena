"""Small process-local sliding window limiter keyed by client identity."""
import time
from collections import defaultdict, deque
from threading import Lock


class SlidingWindowLimiter:
    def __init__(self, max_keys: int = 1024):
        self._events = defaultdict(deque)
        self._lock = Lock()
        self._max_keys = max_keys

    def allow(self, key: str, limit: int, window_seconds: int = 60) -> bool:
        now = time.monotonic()
        with self._lock:
            # Bound memory: if keys exceed max_keys, evict empty or stale buckets
            if len(self._events) > self._max_keys:
                stale_keys = [
                    k for k, q in self._events.items()
                    if not q or q[-1] <= now - window_seconds
                ]
                for k in stale_keys:
                    self._events.pop(k, None)
                # If still over limit, pop arbitrary oldest keys
                if len(self._events) > self._max_keys:
                    for k in list(self._events.keys())[:len(self._events) - self._max_keys]:
                        self._events.pop(k, None)

            events = self._events[key]
            while events and events[0] <= now - window_seconds:
                events.popleft()
            if len(events) >= limit:
                return False
            events.append(now)
            return True


limiter = SlidingWindowLimiter()
