"""NAS Hub agent: stats système et pilotage local des appareils pour l'app Android.

Aucun secret de service tiers ici : la clé Jellyfin est saisie dans l'app."""
import json
import os
import re
import threading
import time
from collections import deque
from contextlib import asynccontextmanager

import psutil
from fastapi import Depends, FastAPI

from .auth import auth
from .devices import router as devices_router

# Racine du système hôte montée dans le conteneur (voir docker-compose.yml). Vide = pas de conteneur.
HOST_ROOT = os.environ.get("HOST_ROOT", "/host")
# Repli manuel si la détection des disques ne trouve rien : "nom=chemin" séparés par des virgules
DISK_PATHS = os.environ.get("DISK_PATHS", "Système=/")
# Interface réseau à mesurer (sinon : toutes les interfaces physiques)
NET_IFACE = os.environ.get("NET_IFACE", "")

NET_SKIP = ("lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "tailscale", "zt", "tun", "tap")
NET_SAMPLE_S = 2
NET_HISTORY_POINTS = 150  # 5 minutes

REAL_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "ntfs", "ntfs3", "fuseblk", "exfat", "f2fs", "vfat"}
SKIP_MOUNTS = ("/boot", "/var/lib/docker", "/var/lib/containers", "/snap", "/run", "/sys", "/proc", "/dev", "/tmp")

net_history: deque = deque(maxlen=NET_HISTORY_POINTS)  # [timestamp, down_bps, up_bps]


def net_totals() -> tuple[int, int]:
    recv = sent = 0
    for name, io in psutil.net_io_counters(pernic=True).items():
        if NET_IFACE:
            if name != NET_IFACE:
                continue
        elif name.startswith(NET_SKIP):
            continue
        recv += io.bytes_recv
        sent += io.bytes_sent
    return recv, sent


def sample_network():
    last_t, (last_r, last_s) = time.time(), net_totals()
    while True:
        time.sleep(NET_SAMPLE_S)
        now, (r, s) = time.time(), net_totals()
        dt = max(now - last_t, 1e-3)
        net_history.append([round(now, 1), max(r - last_r, 0) / dt, max(s - last_s, 0) / dt])
        last_t, last_r, last_s = now, r, s


@asynccontextmanager
async def lifespan(_: FastAPI):
    threading.Thread(target=sample_network, daemon=True).start()
    yield


app = FastAPI(title="NAS Hub agent", lifespan=lifespan)
app.include_router(devices_router)


def cpu_temperature() -> float | None:
    try:
        sensors = psutil.sensors_temperatures()
    except Exception:
        return None
    # Ordre de préférence selon les plateformes (Intel, AMD, ARM/Raspberry)
    for key in ("coretemp", "k10temp", "zenpower", "cpu_thermal", "cpu-thermal"):
        entries = sensors.get(key)
        if entries:
            package = next((e for e in entries if "package" in (e.label or "").lower()), entries[0])
            return package.current
    for entries in sensors.values():
        if entries:
            return entries[0].current
    return None


def detect_disks() -> list[dict]:
    """Tous les disques montés sur l'hôte (via la racine montée dans HOST_ROOT), sans doublon."""
    by_device: dict[str, dict] = {}
    try:
        lines = open("/proc/mounts").read().splitlines()
    except OSError:
        return []
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        dev, mp, fs = parts[0], parts[1].encode().decode("unicode_escape"), parts[2]
        if fs not in REAL_FS or not (mp == HOST_ROOT or mp.startswith(HOST_ROOT + "/") or HOST_ROOT == ""):
            continue
        rel = mp[len(HOST_ROOT):] or "/"
        if rel.startswith(SKIP_MOUNTS):
            continue
        try:
            u = psutil.disk_usage(mp)
        except OSError:
            continue
        if u.total < 1_000_000_000:
            continue
        # Plusieurs montages du même disque (sous-volumes btrfs...) : on garde le plus court.
        if dev in by_device and len(by_device[dev]["path"]) <= len(rel):
            continue
        name = "Système" if rel == "/" else os.path.basename(rel.rstrip("/")) or rel
        by_device[dev] = {"name": name, "path": rel, "device": dev, "fstype": fs,
                          "total": u.total, "used": u.used, "percent": u.percent}
    return sorted(by_device.values(), key=lambda d: (d["path"] != "/", d["path"]))


def configured_disks() -> list[dict]:
    disks = []
    for item in DISK_PATHS.split(","):
        name, _, path = item.partition("=")
        try:
            u = psutil.disk_usage(path.strip())
        except OSError:
            continue
        disks.append({"name": name.strip(), "path": path.strip(), "device": "", "fstype": "",
                      "total": u.total, "used": u.used, "percent": u.percent})
    return disks


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/system", dependencies=[Depends(auth)])
def system():
    cores = psutil.cpu_percent(interval=0.3, percpu=True)
    mem, swap = psutil.virtual_memory(), psutil.swap_memory()
    last = net_history[-1] if net_history else [0, 0.0, 0.0]
    return {
        "cpu_percent": round(sum(cores) / len(cores), 1),
        "cpu_per_core": cores,
        "cpu_temp": cpu_temperature(),
        "load": os.getloadavg(),
        "ram": {"total": mem.total, "used": mem.total - mem.available, "percent": mem.percent},
        "swap": {"total": swap.total, "used": swap.used, "percent": swap.percent},
        "disks": detect_disks() or configured_disks(),
        "net": {"down_bps": last[1], "up_bps": last[2]},
        "net_history": {"interval_s": NET_SAMPLE_S,
                        "down": [round(p[1]) for p in net_history],
                        "up": [round(p[2]) for p in net_history]},
        "uptime_s": int(time.time() - psutil.boot_time()),
    }


# ---- Programmes les plus gourmands en RAM

_CONTAINER_ID = re.compile(r"([0-9a-f]{64})")
_container_names: dict[str, str] = {}


def container_name(cid: str) -> str | None:
    """Nom du conteneur Docker (lu dans ses fichiers de config, sans passer par l'API Docker)."""
    if cid not in _container_names:
        path = f"{HOST_ROOT}/var/lib/docker/containers/{cid}/config.v2.json"
        try:
            with open(path) as f:
                _container_names[cid] = json.load(f).get("Name", "").lstrip("/")
        except (OSError, ValueError):
            _container_names[cid] = ""
    return _container_names[cid] or None


def process_container_id(pid: int) -> str | None:
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            m = _CONTAINER_ID.search(f.read())
    except OSError:
        return None
    return m.group(1) if m else None


@app.get("/api/processes", dependencies=[Depends(auth)])
def processes(limit: int = 8):
    """Regroupe par conteneur Docker (sinon par nom de programme) et trie par RAM utilisée."""
    total = psutil.virtual_memory().total
    groups: dict[str, dict] = {}
    for p in psutil.process_iter(["pid", "name", "memory_info"]):
        mi = p.info["memory_info"]
        if mi is None:
            continue
        cid = process_container_id(p.info["pid"])
        cname = container_name(cid) if cid else None
        key = f"c:{cname}" if cname else f"p:{p.info['name']}"
        g = groups.setdefault(key, {"name": cname or p.info["name"],
                                    "kind": "container" if cname else "process", "ram": 0, "count": 0})
        g["ram"] += mi.rss
        g["count"] += 1
    top = sorted(groups.values(), key=lambda g: g["ram"], reverse=True)[:max(1, min(limit, 30))]
    return [{**g, "percent": round(g["ram"] * 100 / total, 1)} for g in top]
