"""Novatrix ärendeformulär -- tar emot ett ärende och en bilaga och sparar dem som blobar.

Ingen nyckel någonstans. Maskinens hanterade identitet hämtar en token från
Azures metadata-endpoint, och varje skrivning är ett HTTPS PUT mot Blob-API:t.
Var lagringen finns står i /etc/mov/deploy.env, skrivet av mov vid deploy.
"""

from __future__ import annotations

import json
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from flask import Flask, jsonify, request

ACCOUNT = os.environ["NOVATRIX_STORAGE_ACCOUNT"]
ENDPOINT = (os.environ.get("NOVATRIX_BLOB_ENDPOINT") or f"https://{ACCOUNT}.blob.core.windows.net/").rstrip("/")
CONTAINER = os.environ.get("NOVATRIX_CONTAINER", "arenden")

IMDS = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F"
)
API_VERSION = "2023-11-03"
MAX_ATTACHMENT = 10 * 1024 * 1024

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_ATTACHMENT + 64 * 1024

_token: dict = {"value": None, "expires": 0.0}


def token() -> str:
    """En token för identiteten, återanvänd tills strax innan den går ut."""
    now = time.time()
    if _token["value"] and _token["expires"] - now > 120:
        return _token["value"]
    req = urllib.request.Request(IMDS, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=10) as answer:
        body = json.load(answer)
    _token.update(value=body["access_token"], expires=now + int(body.get("expires_in", 3600)))
    return _token["value"]


def put_blob(name: str, data: bytes, content_type: str) -> int:
    url = f"{ENDPOINT}/{CONTAINER}/{urllib.parse.quote(name)}"
    req = urllib.request.Request(url, data=data, method="PUT", headers={
        "Authorization": f"Bearer {token()}",
        "x-ms-version": API_VERSION,
        "x-ms-blob-type": "BlockBlob",
        "Content-Type": content_type,
        "Content-Length": str(len(data)),
    })
    with urllib.request.urlopen(req, timeout=30) as answer:
        return answer.status


def count_blobs() -> int:
    url = f"{ENDPOINT}/{CONTAINER}?restype=container&comp=list&maxresults=5000"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}", "x-ms-version": API_VERSION})
    with urllib.request.urlopen(req, timeout=30) as answer:
        return answer.read().decode("utf-8", errors="replace").count("<Blob>")


@app.get("/health")
def health():
    try:
        blobs = count_blobs()
    except Exception as error:  # noqa: BLE001 -- the answer is the diagnosis
        return jsonify(status="degraded", storage=ACCOUNT, container=CONTAINER, error=str(error)[:200]), 503
    return jsonify(status="ok", storage=ACCOUNT, container=CONTAINER, blobs=blobs)


@app.post("/arenden")
def submit():
    form = request.form
    missing = [field for field in ("name", "email", "message") if not form.get(field, "").strip()]
    if missing:
        return jsonify(error="saknas: " + ", ".join(missing)), 400

    received = datetime.now(timezone.utc)
    ident = received.strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    record = {
        "id": ident,
        "receivedAt": received.isoformat(timespec="seconds"),
        "name": form["name"].strip(),
        "email": form["email"].strip(),
        "message": form["message"].strip(),
        "attachment": None,
    }

    upload = request.files.get("attachment")
    if upload is not None and upload.filename:
        data = upload.read()
        if len(data) > MAX_ATTACHMENT:
            return jsonify(error="bilagan är större än 10 MB"), 413
        safe = os.path.basename(upload.filename).replace(" ", "_")[:120] or "bilaga"
        put_blob(f"{ident}/{safe}", data, upload.mimetype or "application/octet-stream")
        record["attachment"] = {"name": safe, "bytes": len(data), "type": upload.mimetype}

    put_blob(f"{ident}/arende.json", json.dumps(record, ensure_ascii=False, indent=2).encode("utf-8"), "application/json")

    if request.args.get("format") == "json":
        return jsonify(status="stored", id=ident, attachment=record["attachment"])
    return (
        "<!DOCTYPE html><html lang='sv'><head><meta charset='UTF-8'><title>Novatrix - Tack</title>"
        "<link rel='stylesheet' href='/style.css'></head><body><div class='container'>"
        f"<h1>Tack!</h1><p>Ärende <code>{ident}</code> är sparat.</p><p><a href='/'>Tillbaka</a></p>"
        "</div></body></html>"
    )


@app.errorhandler(urllib.error.HTTPError)
def storage_refused(error: urllib.error.HTTPError):
    """Azure sa nej. Statusen är hela diagnosen: 403 är en roll som saknas,
    en nätverksregel som stänger ute, eller en token för fel resurs."""
    return jsonify(error="lagringen nekade skrivningen", status=error.code, reason=error.reason), 502
