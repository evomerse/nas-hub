"""LEDs et prises pilotés en local.

Deux familles d'appareils, enregistrées dans devices.json (géré par l'app) :
- Tuya (Smart Life, Konyks...) via tinytuya : besoin de l'id et de la clé locale.
- Magic Home / Zengge (Surplife...) via flux_led : besoin seulement de l'adresse IP.

[{"name": "LEDs salon", "id": "...", "key": "...", "ip": "192.168.1.30", "version": "3.4",
  "category": "dj", "kind": "light"},
 {"name": "Bandeau", "id": "E8CA50125193", "ip": "192.168.1.149", "protocol": "magichome",
  "kind": "light"}]
"""
import json
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import psutil
import tinytuya
from fastapi import APIRouter, Depends, HTTPException
from flux_led import WifiLedBulb
from pydantic import BaseModel, Field

from .auth import auth

DEVICES_FILE = os.environ.get("TUYA_DEVICES", "/config/devices.json")
LIGHT_CATEGORIES = {"dj", "dc", "xdd", "fwd", "tgq", "tgkg", "dd"}  # ampoules, bandeaux, guirlandes
TIMER_DPS = "9"  # compte à rebours des prises Tuya standard (secondes)

router = APIRouter(prefix="/api/devices", dependencies=[Depends(auth)])


class Unsupported(Exception):
    """Fonction absente sur cet appareil."""


# ---------------------------------------------------------------- Tuya

class TuyaDriver:
    def __init__(self, conf: dict, kind: str):
        self.kind = kind
        cls = tinytuya.BulbDevice if kind == "light" else tinytuya.OutletDevice
        self.dev = cls(conf["id"], address=conf.get("ip") or "Auto", local_key=conf.get("key", ""),
                       version=float(conf.get("version") or 3.3))
        self.dev.set_socketPersistent(False)
        self.dev.set_socketTimeout(3)
        self.dev.set_socketRetryLimit(1)

    @staticmethod
    def _check(res):
        if isinstance(res, dict) and "Error" in res:
            raise RuntimeError(res["Error"])

    def state(self) -> dict:
        return self._light_state() if self.kind == "light" else self._plug_state()

    def _light_state(self) -> dict:
        d = self.dev
        st = d.state()
        self._check(st)
        out = {"on": bool(st.get("is_on")), "brightness": None, "color": None,
               "mode": st.get("mode"), "timer": None, "caps": ["color", "white"]}
        raw = st.get("brightness")
        if raw is not None:
            lo, hi = d.dpset.get("value_min", 10), d.dpset.get("value_max", 1000)
            out["brightness"] = max(1, min(100, round((raw - lo) / (hi - lo) * 99) + 1))
        if st.get("mode") == "colour":
            try:
                r, g, b = d.colour_rgb(state=st)
                out["color"] = f"#{int(r):02x}{int(g):02x}{int(b):02x}"
            except Exception:
                pass
        return out

    def _plug_state(self) -> dict:
        res = self.dev.status()
        self._check(res)
        dps = res.get("dps", {})
        # La plupart des prises : dps "1" = interrupteur. Sinon le premier booléen.
        on = dps.get("1")
        if not isinstance(on, bool):
            on = next((v for v in dps.values() if isinstance(v, bool)), False)
        timer = dps.get(TIMER_DPS)
        return {"on": on, "brightness": None, "color": None, "mode": None,
                "timer": timer if isinstance(timer, int) and timer > 0 else None, "caps": ["timer"]}

    def power(self, on: bool):
        self._check(self.dev.turn_on() if on else self.dev.turn_off())

    def set_brightness(self, value: int):
        self._check(self.dev.set_brightness_percentage(value))

    def set_color(self, r: int, g: int, b: int):
        self._check(self.dev.set_colour(r, g, b))

    def set_white(self, temp: int, brightness: int):
        self._check(self.dev.set_white_percentage(brightness, temp))

    def set_timer(self, seconds: int):
        if self.kind != "plug":
            raise Unsupported("Le minuteur est réservé aux prises")
        self._check(self.dev.set_value(TIMER_DPS, seconds))


# ---------------------------------------------------------------- Magic Home / Zengge (Surplife)

def broadcast_addresses() -> list[str]:
    out = {"255.255.255.255"}
    for addrs in psutil.net_if_addrs().values():
        for a in addrs:
            if a.family == socket.AF_INET and a.broadcast and not a.address.startswith("127."):
                out.add(a.broadcast)
    return sorted(out)


def scan_magichome(timeout: float = 3.0) -> list[dict]:
    """Découverte UDP (port 48899) : chaque contrôleur répond « IP,MAC,MODÈLE »."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.5)
    found: dict[str, dict] = {}
    try:
        for _ in range(2):
            for b in broadcast_addresses():
                try:
                    s.sendto(b"HF-A11ASSISTHREAD", (b, 48899))
                except OSError:
                    pass
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = s.recvfrom(1024)
            except socket.timeout:
                continue
            parts = data.decode(errors="ignore").strip().split(",")
            if len(parts) >= 3:
                found[parts[1]] = {"ip": parts[0], "mac": parts[1], "model": parts[2]}
    finally:
        s.close()
    return list(found.values())


class MagicHomeDriver:
    kind = "light"

    FADE_S = 1.2  # le contrôleur fait un fondu : on attend sa fin avant de relire l'état

    def __init__(self, conf: dict, entry: "Entry"):
        self.entry = entry
        self._written_at = 0.0
        self._target = 255  # dernière intensité demandée (0..255)

    def _settle(self):
        wait = self._written_at + self.FADE_S - time.time()
        if wait > 0:
            time.sleep(wait)

    def _open(self) -> WifiLedBulb:
        conf = self.entry.conf
        try:
            return WifiLedBulb(conf["ip"], timeout=4)
        except OSError:
            # L'IP a pu changer (DHCP) : on retrouve le contrôleur par son adresse MAC.
            for d in scan_magichome(2.5):
                if d["mac"] == conf["id"] and d["ip"] != conf["ip"]:
                    conf["ip"] = d["ip"]
                    persist()
                    return WifiLedBulb(d["ip"], timeout=4)
            raise RuntimeError("Contrôleur injoignable")

    @staticmethod
    def _full(rgb) -> tuple[int, int, int]:
        """Couleur ramenée à pleine intensité (la luminosité est gérée à part)."""
        r, g, b = rgb
        m = max(r, g, b)
        if m == 0:
            return 255, 255, 255
        return round(r * 255 / m), round(g * 255 / m), round(b * 255 / m)

    def state(self) -> dict:
        self._settle()
        b = self._open()
        try:
            r, g, bl = self._full(b.rgb)
            self._target = b.brightness or self._target
            return {"on": bool(b.is_on), "brightness": max(1, round(b.brightness * 100 / 255)),
                    "color": f"#{r:02x}{g:02x}{bl:02x}", "mode": "colour", "timer": None, "caps": ["color"]}
        finally:
            b.close()

    def power(self, on: bool):
        b = self._open()
        try:
            b.turnOn() if on else b.turnOff()
            self._written_at = time.time()
        finally:
            b.close()

    def set_brightness(self, value: int):
        b = self._open()
        try:
            r, g, bl = self._full(b.rgb)
            self._target = max(1, round(value * 255 / 100))
            b.setRgb(r, g, bl, brightness=self._target)
            self._written_at = time.time()
        finally:
            b.close()

    def set_color(self, r: int, g: int, b: int):
        bulb = self._open()
        try:
            bulb.setRgb(r, g, b, brightness=self._target)
            self._written_at = time.time()
        finally:
            bulb.close()

    def set_white(self, temp: int, brightness: int):
        raise Unsupported("Ce contrôleur ne gère pas le blanc")

    def set_timer(self, seconds: int):
        raise Unsupported("Le minuteur est réservé aux prises")


# ---------------------------------------------------------------- Registre

class Entry:
    def __init__(self, conf: dict):
        self.conf = conf
        self.id = conf["id"]
        self.name = conf.get("name", self.id)
        self.lock = threading.Lock()
        if conf.get("protocol") == "magichome":
            self.kind = "light"
            self.driver = MagicHomeDriver(conf, self)
        else:
            self.kind = conf.get("kind") or ("light" if conf.get("category") in LIGHT_CATEGORIES else "plug")
            self.driver = TuyaDriver(conf, self.kind)


_entries: dict[str, Entry] | None = None


def entries() -> dict[str, Entry]:
    global _entries
    if _entries is None:
        try:
            with open(DEVICES_FILE) as f:
                _entries = {c["id"]: Entry(c) for c in json.load(f)}
        except FileNotFoundError:
            _entries = {}
    return _entries


def _write(confs: list[dict]) -> None:
    os.makedirs(os.path.dirname(DEVICES_FILE), exist_ok=True)
    with open(DEVICES_FILE, "w") as f:
        json.dump(confs, f, indent=2, ensure_ascii=False)


def save(confs: list[dict]) -> None:
    global _entries
    _write(confs)
    _entries = None  # rechargé à la prochaine requête


def persist() -> None:
    """Réécrit le fichier avec la configuration en mémoire (ex : nouvelle IP)."""
    _write([e.conf for e in entries().values()])


def get_entry(dev_id: str) -> Entry:
    e = entries().get(dev_id)
    if not e:
        raise HTTPException(status_code=404, detail="Appareil inconnu")
    return e


def describe(e: Entry) -> dict:
    base = {"id": e.id, "name": e.name, "kind": e.kind}
    try:
        with e.lock:
            return {**base, "online": True, **e.driver.state()}
    except Exception as ex:
        return {**base, "online": False, "on": False, "brightness": None, "color": None,
                "mode": None, "timer": None, "caps": [], "error": str(ex)}


@router.get("")
def list_devices():
    items = list(entries().values())
    with ThreadPoolExecutor(max_workers=max(len(items), 1)) as pool:
        return list(pool.map(describe, items))


def run(dev_id: str, fn):
    """Exécute une commande sur l'appareil en traduisant les erreurs en réponses HTTP."""
    e = get_entry(dev_id)
    try:
        with e.lock:
            fn(e.driver)
    except Unsupported as ex:
        raise HTTPException(status_code=400, detail=str(ex))
    except HTTPException:
        raise
    except Exception as ex:
        raise HTTPException(status_code=502, detail=str(ex))
    return {"ok": True}


class Power(BaseModel):
    on: bool


class Brightness(BaseModel):
    value: int = Field(ge=1, le=100)


class Color(BaseModel):
    hex: str = Field(pattern=r"^#?[0-9a-fA-F]{6}$")


class White(BaseModel):
    temp: int = Field(ge=0, le=100)  # 0 = chaud, 100 = froid
    brightness: int = Field(default=100, ge=1, le=100)


class Timer(BaseModel):
    seconds: int = Field(ge=0, le=86400)  # 0 = annuler


@router.post("/{dev_id}/power")
def power(dev_id: str, body: Power):
    return run(dev_id, lambda d: d.power(body.on))


@router.post("/{dev_id}/brightness")
def brightness(dev_id: str, body: Brightness):
    return run(dev_id, lambda d: d.set_brightness(body.value))


@router.post("/{dev_id}/color")
def color(dev_id: str, body: Color):
    h = body.hex.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return run(dev_id, lambda d: d.set_color(r, g, b))


@router.post("/{dev_id}/white")
def white(dev_id: str, body: White):
    return run(dev_id, lambda d: d.set_white(body.temp, body.brightness))


@router.post("/{dev_id}/timer")
def timer(dev_id: str, body: Timer):
    """Compte à rebours de la prise : à la fin, elle change d'état (allumée -> éteinte)."""
    return run(dev_id, lambda d: d.set_timer(body.seconds))


@router.delete("/{dev_id}")
def remove(dev_id: str):
    get_entry(dev_id)
    save([e.conf for i, e in entries().items() if i != dev_id])
    return {"ok": True}


# ---------------------------------------------------------------- Ajout : réseau local (Surplife / Magic Home)

class AddLocal(BaseModel):
    mac: str
    ip: str
    name: str = "LEDs"


@router.get("/scan-local")
def scan_local():
    """Contrôleurs Magic Home / Zengge (Surplife...) trouvés sur le réseau, pas encore ajoutés."""
    known = entries()
    return [{**d, "added": d["mac"] in known} for d in scan_magichome(3.0)]


@router.post("/add-local")
def add_local(body: AddLocal):
    confs = [e.conf for e in entries().values()]
    if all(c["id"] != body.mac for c in confs):
        confs.append({"name": body.name, "id": body.mac, "ip": body.ip,
                      "protocol": "magichome", "kind": "light"})
        save(confs)
    return {"ok": True}


# ---------------------------------------------------------------- Ajout : import depuis le compte Tuya IoT

_pending: dict[str, dict] = {}  # appareils trouvés, avec leur clé (qui ne quitte jamais l'agent)
_pending_at = 0.0


class CloudImport(BaseModel):
    access_id: str
    secret: str
    region: str = Field(pattern=r"^(eu|eu-w|us|us-e|cn|in|sg)$")
    device_id: str  # l'id d'un appareil quelconque du compte (sert à retrouver le compte)


class AddDevices(BaseModel):
    ids: list[str]


@router.post("/import")
def import_cloud(body: CloudImport):
    """Liste les appareils du compte Tuya (+ IP trouvées sur le réseau local)."""
    global _pending, _pending_at
    cloud = tinytuya.Cloud(apiRegion=body.region, apiKey=body.access_id, apiSecret=body.secret,
                           apiDeviceID=body.device_id)
    found = cloud.getdevices()
    if isinstance(found, dict) and ("Error" in found or "Err" in found):
        raise HTTPException(status_code=400, detail=str(found.get("Error") or found))
    try:
        scan = tinytuya.deviceScan(False, 6, False, False, False, True)  # IP et version par id
    except Exception:
        scan = {}
    _pending = {}
    for d in found:
        if d.get("sub") or not d.get("key"):
            continue
        net = scan.get(d["id"], {})
        _pending[d["id"]] = {
            "id": d["id"], "name": d.get("name") or d["id"], "key": d["key"],
            "category": d.get("category", ""), "ip": net.get("ip", ""),
            "version": str(net.get("version") or "3.4"),
        }
    _pending_at = time.time()
    known = entries()
    return [{"id": p["id"], "name": p["name"], "category": p["category"], "ip": p["ip"],
             "kind": "light" if p["category"] in LIGHT_CATEGORIES else "plug",
             "added": p["id"] in known} for p in _pending.values()]


@router.post("/add")
def add_devices(body: AddDevices):
    if time.time() - _pending_at > 900:
        raise HTTPException(status_code=410, detail="Import expiré, relance la recherche")
    confs = [e.conf for e in entries().values()]
    have = {c["id"] for c in confs}
    for i in body.ids:
        if i in _pending and i not in have:
            confs.append(_pending[i])
    save(confs)
    return {"ok": True}
