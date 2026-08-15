"""Shared rclpy init — avoids 'Context.init() must only be called once'."""
import logging
import threading

log = logging.getLogger(__name__)
_lock = threading.Lock()


def ensure_rclpy() -> bool:
    """Initialize rclpy once. Returns False if rclpy is not installed."""
    try:
        import rclpy
    except ImportError:
        return False
    with _lock:
        try:
            if not rclpy.ok():
                rclpy.init(args=None)
        except RuntimeError as exc:
            if "must only be called once" not in str(exc):
                raise
            log.debug("rclpy already initialized: %s", exc)
    return True
