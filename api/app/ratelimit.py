"""Application level rate limiting.

Cloud Armor enforces the real limit at the edge in GCP. This is the
in-process fallback so the protection still exists when the service runs
locally or behind a different ingress. It is a fixed window per client,
which is enough for abuse control and cheap to reason about.
"""

from __future__ import annotations

import threading
import time


class FixedWindowRateLimiter:
    def __init__(self, limit_per_minute: int) -> None:
        self.limit = limit_per_minute
        self._lock = threading.Lock()
        self._windows: dict[str, tuple[int, int]] = {}

    def allow(self, key: str, now: float | None = None) -> bool:
        if self.limit <= 0:
            return True

        current = int(now if now is not None else time.time()) // 60
        with self._lock:
            window, count = self._windows.get(key, (current, 0))
            if window != current:
                window, count = current, 0
            if count >= self.limit:
                self._windows[key] = (window, count)
                return False
            self._windows[key] = (window, count + 1)
            return True
