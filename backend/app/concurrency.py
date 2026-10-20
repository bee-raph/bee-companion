"""Serialize duplicate provider fetches without blocking unrelated cache keys."""

from contextlib import contextmanager
from functools import wraps
import threading

_guard = threading.Lock()
_locks = {}


@contextmanager
def keyed_lock(key):
    with _guard:
        lock, users = _locks.get(key, (threading.Lock(), 0))
        _locks[key] = (lock, users + 1)
    try:
        with lock:
            yield
    finally:
        with _guard:
            _, users = _locks[key]
            if users == 1:
                del _locks[key]
            else:
                _locks[key] = (lock, users - 1)


def singleflight(key):
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            with keyed_lock(key(*args, **kwargs)):
                return function(*args, **kwargs)

        return wrapped

    return decorate
