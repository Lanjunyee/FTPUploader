"""Opt-in, secret-free numeric counters for disposable protocol fixtures."""
import json
import os
import threading


class FixtureCounts:
    EVENTS = ('listings', 'connections', 'authentications')

    def __init__(self, path=None):
        self.path = path
        self.lock = threading.Lock()
        self.totals = dict.fromkeys(self.EVENTS, 0)
        if path is not None:
            self._publish()

    def _publish(self):
        temporary = self.path.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.totals, sort_keys=True))
        os.replace(temporary, self.path)

    def record(self, event):
        if event not in self.EVENTS:
            raise ValueError('Unknown counter event')
        if self.path is None:
            return
        with self.lock:
            self.totals[event] += 1
            self._publish()
