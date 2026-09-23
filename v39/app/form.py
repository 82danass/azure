"""Novatrix ärendeformulär, v39: ärendet blir en rad i ärenderegistret.

Registret är NocoDB på ops-maskinen, nått över det privata nätet på VM-namnet.
Tjänsten loggar in med registrets adminkonto (lösenordet kommer från
/etc/mov/secrets.env, som mov levererar efter boot, aldrig via cloud-init),
hittar basen och tabellen på namn, och skriver raden med registrets API.
Ingen nyckel i koden, inget i repot.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)

TICKETS_URL = os.environ["NOVATRIX_TICKETS_URL"].rstrip("/")
ADMIN_EMAIL = os.environ["NC_ADMIN_EMAIL"]
ADMIN_PASSWORD = os.environ["NC_ADMIN_PASSWORD"]
BASE_TITLE = os.environ.get("NOVATRIX_BASE", "Novatrix")
TABLE_TITLE = os.environ.get("NOVATRIX_TABLE", "Arenden")

_lock = threading.Lock()
_session: dict[str, object] = {"jwt": None, "until": 0.0, "table": None}


def _call(method: str, path: str, body: dict | None = None, *, jwt: str | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if jwt:
        headers["xc-auth"] = jwt
    req = urllib.request.Request(f"{TICKETS_URL}{path}", data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as answer:
        text = answer.read().decode("utf-8", errors="replace")
    return json.loads(text) if text else {}


def _jwt(fresh: bool = False) -> str:
    """Registrets adminsession. Den dör inte bara av ålder: registret drar
    tillbaka den när samma konto loggar in på nytt någon annanstans, så en
    nekad session byts mot en ny (fresh=True) i stället för att svaret blir
    502 resten av dagen."""
    with _lock:
        if _session["jwt"] and not fresh:
            return str(_session["jwt"])
        answer = _call("POST", "/api/v2/auth/user/signin", {"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD})
        _session["jwt"] = answer["token"]
        return str(_session["jwt"])


def _registry(method: str, path: str, body: dict | None = None) -> dict:
    """Ett anrop med adminsessionen; nekas det, en gång till med en ny."""
    try:
        return _call(method, path, body, jwt=_jwt())
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        return _call(method, path, body, jwt=_jwt(fresh=True))


def _table_id() -> str:
    """Tabellen på namn, en gång per process. Basen och tabellen skapas av
    ops-maskinens startskript; här hittas de bara."""
    if _session["table"]:
        return str(_session["table"])
    bases = _registry("GET", "/api/v1/db/meta/projects/").get("list", [])
    base = next((b for b in bases if b.get("title") == BASE_TITLE), None)
    if base is None:
        raise LookupError(f"basen {BASE_TITLE!r} finns inte i registret")
    tables = _registry("GET", f"/api/v2/meta/bases/{base['id']}/tables").get("list", [])
    table = next((t for t in tables if t.get("title") == TABLE_TITLE), None)
    if table is None:
        raise LookupError(f"tabellen {TABLE_TITLE!r} finns inte i basen {BASE_TITLE!r}")
    _session["table"] = table["id"]
    return str(table["id"])


@app.get("/health")
def health():
    try:
        table = _table_id()
        where = urllib.parse.quote("(Status,eq,ny)")
        found = _registry("GET", f"/api/v2/tables/{table}/records?where={where}&limit=1")
        open_tickets = int((found.get("pageInfo") or {}).get("totalRows") or 0)
    except Exception as error:  # noqa: BLE001 -- svaret är diagnosen
        return jsonify(status="degraded", registry=TICKETS_URL, error=str(error)[:200]), 503
    return jsonify(status="ok", registry=TICKETS_URL, table=TABLE_TITLE, open=open_tickets)


@app.post("/arenden")
def submit():
    form = request.form
    missing = [field for field in ("name", "email", "message") if not form.get(field, "").strip()]
    if missing:
        return jsonify(error="saknas: " + ", ".join(missing)), 400

    received = datetime.now(timezone.utc).isoformat(timespec="seconds")
    row = {
        "Name": form["name"].strip()[:200],
        "Email": form["email"].strip()[:200],
        "Message": form["message"].strip()[:5000],
        "Status": "ny",
        "Received": received,
    }
    created = _registry("POST", f"/api/v2/tables/{_table_id()}/records", row)
    ident = created[0]["Id"] if isinstance(created, list) else created.get("Id")

    if request.args.get("format") == "json":
        return jsonify(status="stored", id=ident)
    return (
        "<!DOCTYPE html><html lang='sv'><head><meta charset='UTF-8'><title>Novatrix - Tack</title>"
        "<link rel='stylesheet' href='/style.css'></head><body><div class='container'>"
        f"<h1>Tack!</h1><p>Ärende <code>#{ident}</code> är registrerat. Kundtjänst ser det nu.</p>"
        "<p><a href='/'>Tillbaka</a></p></div></body></html>"
    )


@app.errorhandler(urllib.error.HTTPError)
def registry_refused(error: urllib.error.HTTPError):
    return jsonify(error="ärenderegistret nekade", status=error.code, reason=error.reason), 502


@app.errorhandler(urllib.error.URLError)
def registry_unreachable(error: urllib.error.URLError):
    return jsonify(error="ärenderegistret svarar inte", reason=str(error.reason)[:200]), 502


@app.errorhandler(LookupError)
def registry_incomplete(error: LookupError):
    return jsonify(error=str(error)), 503
