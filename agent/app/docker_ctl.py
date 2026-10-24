"""Conteneurs Docker du NAS : liste (à la demande) et commandes classiques.

Passe par le socket Docker monté dans le conteneur (voir docker-compose.yml).

Le rebuild d'un conteneur Docker Compose est lancé dans un petit conteneur d'aide
(image docker:cli) qui monte le dossier du projet au même chemin que sur l'hôte :
les chemins relatifs du docker-compose.yml restent justes, et l'agent peut se
rebuilder lui-même sans couper la commande en cours de route."""
import os
import re
import shlex
import threading

import docker
from docker.errors import APIError, DockerException, NotFound
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import PlainTextResponse

from .auth import auth

# Chemin du socket sur l'hôte (monté tel quel dans le conteneur d'aide).
HOST_SOCKET = os.environ.get("DOCKER_HOST_SOCKET", "/var/run/docker.sock")
HELPER_IMAGE = os.environ.get("DOCKER_HELPER_IMAGE", "docker:cli")
SELF_NAME = os.environ.get("SELF_CONTAINER", "nas-hub-agent")
HELPER_LABEL = "nas-hub.rebuild-for"

ACTIONS = {"start", "stop", "restart", "pause", "unpause", "remove", "rebuild"}

router = APIRouter(prefix="/api/docker", dependencies=[Depends(auth)])

_client = None
_jobs: dict[str, dict] = {}  # rebuilds en préparation ou en échec avant le lancement : clé -> état
_jobs_lock = threading.Lock()


def client():
    global _client
    if _client is None:
        try:
            _client = docker.from_env(timeout=30)
            _client.ping()
        except DockerException:
            _client = None
            raise HTTPException(503, "Docker inaccessible : monte /var/run/docker.sock dans l'agent "
                                     "(voir docker-compose.yml)")
    return _client


def _labels(attrs: dict) -> dict:
    return attrs.get("Labels") or attrs.get("Config", {}).get("Labels") or {}


def _compose(labels: dict) -> dict | None:
    """Projet Docker Compose du conteneur (None s'il n'a pas été créé par Compose)."""
    project = labels.get("com.docker.compose.project")
    service = labels.get("com.docker.compose.service")
    wd = labels.get("com.docker.compose.project.working_dir")
    if not (project and service and wd):
        return None
    files = [f for f in labels.get("com.docker.compose.project.config_files", "").split(",") if f]
    env_files = [f for f in labels.get("com.docker.compose.project.environment_file", "").split(",") if f]
    return {"project": project, "service": service, "working_dir": wd, "files": files, "env_files": env_files}


def _job_key(c: dict) -> str:
    return f"{c['project']}/{c['service']}"


def _helper_name(c: dict) -> str:
    return "nas-hub-rebuild-" + re.sub(r"[^a-zA-Z0-9_.-]", "-", _job_key(c))


def _rebuild_state(cl, comp: dict | None) -> dict | None:
    """État du dernier rebuild de ce service : running, done, error (ou None)."""
    if comp is None:
        return None
    key = _job_key(comp)
    with _jobs_lock:
        job = _jobs.get(key)
    if job:
        return job
    try:
        h = cl.containers.get(_helper_name(comp))
    except NotFound:
        return None
    st = h.attrs["State"]
    if st.get("Running"):
        return {"state": "running"}
    code = st.get("ExitCode", 0)
    return {"state": "done" if code == 0 else "error", "exit_code": code, "finished_at": st.get("FinishedAt")}


@router.get("/containers")
def containers():
    cl = client()
    out = []
    try:
        listed = cl.containers.list(all=True, sparse=True)
    except APIError as e:
        raise HTTPException(502, f"Docker : {e.explanation or e}")
    for c in listed:
        a = c.attrs
        labels = _labels(a)
        if HELPER_LABEL in labels:
            continue  # nos propres conteneurs de rebuild
        name = (a.get("Names") or ["/?"])[0].lstrip("/")
        comp = _compose(labels)
        out.append({
            "id": a["Id"],
            "name": name,
            "image": a.get("Image", ""),
            "state": a.get("State", ""),      # running, exited, paused, restarting, created, dead
            "status": a.get("Status", ""),    # « Up 3 hours (healthy) »
            "project": comp["project"] if comp else None,
            "service": comp["service"] if comp else None,
            "can_rebuild": comp is not None,
            "self": name == SELF_NAME,
            "rebuild": _rebuild_state(cl, comp),
        })
    out.sort(key=lambda x: (x["state"] != "running", (x["project"] or "~").lower(), x["name"].lower()))
    return out


def _get(cl, cid: str):
    try:
        return cl.containers.get(cid)
    except NotFound:
        raise HTTPException(404, "Conteneur introuvable (rescanne la liste)")


def _start_rebuild(cl, comp: dict):
    """Prépare l'image d'aide puis lance « compose pull + up --build » dans un conteneur à part."""
    key = _job_key(comp)
    try:
        try:
            cl.images.get(HELPER_IMAGE)
        except NotFound:
            repo, _, tag = HELPER_IMAGE.partition(":")
            cl.images.pull(repo, tag=tag or "latest")
        try:
            cl.containers.get(_helper_name(comp)).remove(force=True)
        except NotFound:
            pass

        # Le projet, et chaque fichier compose / .env, montés au même chemin que sur l'hôte.
        dirs = {comp["working_dir"]} | {os.path.dirname(f) for f in comp["files"] + comp["env_files"]}
        volumes = {HOST_SOCKET: {"bind": "/var/run/docker.sock", "mode": "rw"}}
        for d in dirs:
            volumes[d] = {"bind": d, "mode": "ro"}

        base = ["docker", "compose", "-p", comp["project"], "--project-directory", comp["working_dir"]]
        for f in comp["files"]:
            base += ["-f", f]
        for f in comp["env_files"]:
            base += ["--env-file", f]
        svc = comp["service"]
        q = lambda args: " ".join(shlex.quote(x) for x in args)  # noqa: E731
        script = (
            f"set -e; echo '>> Rebuild de {svc}'; "
            f"{q(base + ['pull', '--ignore-buildable', '--ignore-pull-failures', svc])} || true; "
            f"{q(base + ['up', '-d', '--build', '--force-recreate', '--no-deps', svc])}; "
            "echo '>> Terminé'"
        )
        cl.containers.run(
            HELPER_IMAGE,
            entrypoint=["sh", "-c"],
            command=[script],
            name=_helper_name(comp),
            working_dir=comp["working_dir"],
            volumes=volumes,
            labels={HELPER_LABEL: key},
            detach=True,
        )
        with _jobs_lock:
            _jobs.pop(key, None)
    except Exception as e:  # noqa: BLE001 : on remonte l'erreur à l'app via la liste
        with _jobs_lock:
            _jobs[key] = {"state": "error", "error": str(getattr(e, "explanation", None) or e)}


@router.post("/containers/{cid}/{action}")
def act(cid: str, action: str):
    if action not in ACTIONS:
        raise HTTPException(400, f"Action inconnue : {action}")
    cl = client()
    c = _get(cl, cid)
    try:
        if action == "rebuild":
            comp = _compose(c.labels)
            if comp is None:
                raise HTTPException(400, "Ce conteneur n'a pas été créé par Docker Compose : rebuild impossible")
            key = _job_key(comp)
            with _jobs_lock:
                if _jobs.get(key, {}).get("state") == "starting":
                    raise HTTPException(409, "Un rebuild est déjà en préparation")
                _jobs[key] = {"state": "starting"}
            threading.Thread(target=_start_rebuild, args=(cl, comp), daemon=True).start()
        elif action == "remove":
            c.remove(force=True)
        elif action in ("stop", "restart"):
            getattr(c, action)(timeout=20)
        else:
            getattr(c, action)()
    except APIError as e:
        raise HTTPException(502, f"Docker : {e.explanation or e}")
    return {"ok": True}


@router.get("/containers/{cid}/logs", response_class=PlainTextResponse)
def logs(cid: str, tail: int = 200):
    c = _get(client(), cid)
    return c.logs(tail=max(10, min(tail, 2000)), timestamps=False).decode(errors="replace")


@router.get("/containers/{cid}/rebuild-logs", response_class=PlainTextResponse)
def rebuild_logs(cid: str):
    cl = client()
    comp = _compose(_get(cl, cid).labels)
    if comp is None:
        raise HTTPException(400, "Pas de rebuild pour ce conteneur")
    with _jobs_lock:
        job = _jobs.get(_job_key(comp))
    if job:
        return "Préparation du rebuild…" if job["state"] == "starting" else f"Échec : {job.get('error', '')}"
    try:
        h = cl.containers.get(_helper_name(comp))
    except NotFound:
        return "Aucun rebuild récent."
    return h.logs(tail=500).decode(errors="replace")
