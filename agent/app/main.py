"""NAS Hub agent: expose les stats système à l'app Android.

Aucun secret de service tiers ici : la clé Jellyfin est saisie dans l'app."""
import os
import time

import psutil
from fastapi import Depends, FastAPI

from .auth import auth
from .devices import router as devices_router

# Points de montage à surveiller, "nom=chemin" séparés par des virgules
DISK_PATHS = os.environ.get("DISK_PATHS", "Système=/")

app = FastAPI(title="NAS Hub agent")
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


_last_net = {"t": time.time(), "io": psutil.net_io_counters()}


def net_rates() -> dict:
    now, io = time.time(), psutil.net_io_counters()
    dt = max(now - _last_net["t"], 1e-3)
    rates = {
        "down_bps": (io.bytes_recv - _last_net["io"].bytes_recv) / dt,
        "up_bps": (io.bytes_sent - _last_net["io"].bytes_sent) / dt,
    }
    _last_net.update(t=now, io=io)
    return rates


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/system", dependencies=[Depends(auth)])
def system():
    cores = psutil.cpu_percent(interval=0.3, percpu=True)
    mem, swap = psutil.virtual_memory(), psutil.swap_memory()
    disks = []
    for item in DISK_PATHS.split(","):
        name, _, path = item.partition("=")
        try:
            u = psutil.disk_usage(path.strip())
        except OSError:
            continue
        disks.append({"name": name.strip(), "path": path.strip(),
                      "total": u.total, "used": u.used, "percent": u.percent})
    return {
        "cpu_percent": round(sum(cores) / len(cores), 1),
        "cpu_per_core": cores,
        "cpu_temp": cpu_temperature(),
        "load": os.getloadavg(),
        "ram": {"total": mem.total, "used": mem.total - mem.available, "percent": mem.percent},
        "swap": {"total": swap.total, "used": swap.used, "percent": swap.percent},
        "disks": disks,
        "net": net_rates(),
        "uptime_s": int(time.time() - psutil.boot_time()),
    }
