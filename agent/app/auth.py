import os

from fastapi import Header, HTTPException

AGENT_TOKEN = os.environ.get("AGENT_TOKEN", "")


def auth(authorization: str = Header(default="")):
    if not AGENT_TOKEN:
        return
    if authorization != f"Bearer {AGENT_TOKEN}":
        raise HTTPException(status_code=401, detail="Token invalide")
