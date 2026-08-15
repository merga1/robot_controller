#!/usr/bin/env python3
"""Advertise this Raspberry Pi on the local network (UDP + optional mDNS) for the tablet app."""
import getpass
import json
import logging
import re
import socket
import threading
import time

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

SERVICE_TYPE = "_robotcontrol._tcp.local."
UDP_PORT = 9999
API_PORT = 8000
NETWORK_POLL_SEC = 8
UDP_INTERVAL_SEC = 3
DISCOVER_KEY = "robot-control"


def _safe_hostname(name: str) -> str:
    """mDNS names must be lowercase alphanumeric (hostname 'Abpi' breaks zeroconf)."""
    base = name.split(".")[0].lower()
    base = re.sub(r"[^a-z0-9-]", "", base)
    return base or "raspberrypi"


def _subnet_broadcast(ip: str) -> str:
    parts = ip.split(".")
    if len(parts) == 4:
        return ".".join(parts[:3] + ["255"])
    return "255.255.255.255"


def _local_ip() -> str | None:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("8.8.8.8", 80))
            ip = sock.getsockname()[0]
        finally:
            sock.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    return None


def _wait_for_network(timeout_sec: float = 300.0) -> str:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        ip = _local_ip()
        if ip:
            log.info("Network ready — ip=%s", ip)
            return ip
        log.info("Waiting for network...")
        time.sleep(3)
    raise SystemExit("No network IP after timeout — beacon exiting")


def _build_payload(username: str, hostname: str, ip: str) -> dict:
    return {
        "service": DISCOVER_KEY,
        "user": username,
        "host": hostname,
        "ip": ip,
        "api_port": API_PORT,
    }


def _ip_watch(state: dict, lock: threading.Lock) -> None:
    last_ip = state.get("ip") or ""
    while True:
        ip = _local_ip() or ""
        with lock:
            state["ip"] = ip
            if state.get("payload") is not None:
                state["payload"]["ip"] = ip
        if ip and ip != last_ip:
            log.info("IP updated — %s", ip)
            last_ip = ip
        elif not ip and last_ip:
            log.info("Network lost — pausing beacon")
            last_ip = ""
        time.sleep(NETWORK_POLL_SEC)


def _udp_broadcast_loop(state: dict, lock: threading.Lock) -> None:
    """Periodic broadcast to UDP 9999 (tablet listens on same port)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    last_warn = 0.0
    while True:
        with lock:
            ip = state.get("ip") or ""
            payload = dict(state.get("payload") or {})
        if not ip:
            time.sleep(NETWORK_POLL_SEC)
            continue
        payload["ip"] = ip
        message = json.dumps(payload).encode("utf-8")
        targets = {("<broadcast>", UDP_PORT), (_subnet_broadcast(ip), UDP_PORT)}
        for target, port in targets:
            try:
                sock.sendto(message, (target, port))
            except OSError as exc:
                now = time.time()
                if now - last_warn >= 60:
                    log.warning("UDP broadcast paused (will retry): %s", exc)
                    last_warn = now
        time.sleep(UDP_INTERVAL_SEC)


def _udp_listen_loop(state: dict, lock: threading.Lock) -> None:
    """Reply unicast when tablet sends {"discover":"robot-control"}."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", UDP_PORT))
    except OSError as exc:
        log.error("Cannot bind UDP %s (probe/reply disabled): %s", UDP_PORT, exc)
        return

    log.info("UDP listen on port %s (tablet probe → unicast reply)", UDP_PORT)
    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except OSError:
            time.sleep(1)
            continue
        try:
            msg = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if msg.get("discover") != DISCOVER_KEY:
            continue
        with lock:
            ip = state.get("ip") or ""
            payload = dict(state.get("payload") or {})
        if not ip:
            continue
        payload["ip"] = ip
        payload["reply"] = True
        try:
            sock.sendto(json.dumps(payload).encode("utf-8"), addr)
            log.info("Discovery reply → %s:%s ip=%s", addr[0], addr[1], ip)
        except OSError:
            pass


def _mdns_register(service_host: str, username: str, display_host: str, ip: str):
    from zeroconf import ServiceInfo, Zeroconf

    properties = {
        "user": username,
        "host": display_host,
        "api_port": str(API_PORT),
    }
    instance = f"robot-{username}-{service_host}._robotcontrol._tcp.local."
    info = ServiceInfo(
        SERVICE_TYPE,
        instance,
        addresses=[socket.inet_aton(ip)],
        port=API_PORT,
        properties={k: v.encode("utf-8") for k, v in properties.items()},
        server=f"{service_host}.local.",
    )
    zc = Zeroconf()
    zc.register_service(info)
    log.info("mDNS OK — %s ip=%s user=%s", instance, ip, username)
    return zc, info


def _mdns_loop(service_host: str, username: str, display_host: str, state: dict, lock: threading.Lock) -> None:
    try:
        from zeroconf import ServiceInfo  # noqa: F401
    except ImportError:
        log.warning("zeroconf not installed — UDP discovery only (pip3 install zeroconf)")
        return

    zc = None
    info = None
    last_ip = ""
    while True:
        with lock:
            ip = state.get("ip") or ""

        if not ip:
            if zc is not None:
                try:
                    zc.unregister_service(info)
                    zc.close()
                except Exception:
                    pass
                zc = None
                info = None
                last_ip = ""
            time.sleep(NETWORK_POLL_SEC)
            continue

        if ip != last_ip:
            if zc is not None:
                try:
                    zc.unregister_service(info)
                    zc.close()
                except Exception:
                    pass
            try:
                zc, info = _mdns_register(service_host, username, display_host, ip)
                last_ip = ip
            except Exception as exc:
                log.warning("mDNS skipped (UDP still works): %s", exc)
                zc = None
                info = None

        time.sleep(NETWORK_POLL_SEC)


def main() -> None:
    username = getpass.getuser()
    display_host = socket.gethostname().split(".")[0]
    service_host = _safe_hostname(display_host)

    ip = _wait_for_network()
    state: dict = {
        "ip": ip,
        "payload": _build_payload(username, display_host, ip),
    }
    lock = threading.Lock()

    log.info(
        "Robot Pi beacon — user=%s host=%s ip=%s udp_port=%s",
        username,
        display_host,
        ip,
        UDP_PORT,
    )
    threading.Thread(target=_ip_watch, args=(state, lock), daemon=True, name="ip_watch").start()
    threading.Thread(
        target=_udp_listen_loop, args=(state, lock), daemon=True, name="udp_listen"
    ).start()
    threading.Thread(
        target=_udp_broadcast_loop, args=(state, lock), daemon=True, name="udp_broadcast"
    ).start()
    threading.Thread(
        target=_mdns_loop,
        args=(service_host, username, display_host, state, lock),
        daemon=True,
        name="mdns_beacon",
    ).start()

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
