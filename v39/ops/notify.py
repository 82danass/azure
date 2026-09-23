"""Novatrix notifiering, v39: ett nytt ärende blir ett mejl och en notis.

Ärenderegistret (NocoDB) anropar POST /ticket via sin webhook när en rad
skapas. Mejlet går ut genom Azure Communication Services med maskinens
managed identity, ingen nyckel någonstans; avsändaradressen och tjänstens
värdnamn läses från Azure vid start med samma identitet. Notisen går till
Teams genom ett Workflows-webhookflöde, och till Slack om en URL finns.
Webhook-adresserna kommer från /etc/mov/secrets.env, levererad av mov.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import urllib.error
import urllib.request

from azure.communication.email import EmailClient
from azure.identity import DefaultAzureCredential
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("notify")
app = Flask(__name__)

ARM = "https://management.azure.com"
ARM_API = "2023-04-01"
IMDS = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"

ACS_ID = os.environ["NOVATRIX_ACS_ID"]
MAIL_DOMAIN_ID = os.environ["NOVATRIX_MAIL_DOMAIN_ID"]
SUPPORT_EMAIL = os.environ["NOVATRIX_SUPPORT_EMAIL"]
TICKET_HOST = os.environ.get("NOVATRIX_TICKET_HOST", "")
TEAMS_WEBHOOK_URL = os.environ.get("TEAMS_WEBHOOK_URL", "")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")

_state: dict[str, object] = {"sender": None, "endpoint": None, "last": None, "sent": 0, "failed": 0}
_lock = threading.Lock()


def _imds_token() -> str:
    req = urllib.request.Request(IMDS, headers={"Metadata": "true"})
    if os.environ.get("AZURE_CLIENT_ID"):
        req = urllib.request.Request(IMDS + "&client_id=" + os.environ["AZURE_CLIENT_ID"], headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=10) as answer:
        return json.load(answer)["access_token"]


def _arm(resource_id: str) -> dict:
    req = urllib.request.Request(f"{ARM}{resource_id}?api-version={ARM_API}", headers={"Authorization": f"Bearer {_imds_token()}"})
    with urllib.request.urlopen(req, timeout=20) as answer:
        return json.load(answer)


def _mail_setup() -> tuple[str, str]:
    """Avsändaren och tjänstens värdnamn, från resurserna själva."""
    with _lock:
        if _state["sender"] and _state["endpoint"]:
            return str(_state["sender"]), str(_state["endpoint"])
        domain = _arm(MAIL_DOMAIN_ID)["properties"]
        service = _arm(ACS_ID)["properties"]
        _state["sender"] = f"DoNotReply@{domain['mailFromSenderDomain']}"
        _state["endpoint"] = f"https://{service['hostName']}"
        log.info("mail from %s via %s", _state["sender"], _state["endpoint"])
        return str(_state["sender"]), str(_state["endpoint"])


def send_mail(subject: str, body: str) -> str:
    sender, endpoint = _mail_setup()
    client = EmailClient(endpoint, DefaultAzureCredential())
    poller = client.begin_send({
        "senderAddress": sender,
        "recipients": {"to": [{"address": SUPPORT_EMAIL}]},
        "content": {"subject": subject, "plainText": body},
    })
    result = poller.result()
    return str(result.get("status") if isinstance(result, dict) else getattr(result, "status", result))


def _post_json(url: str, payload: dict) -> int:
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as answer:
        return answer.status


def teams_card(ticket: dict) -> dict:
    """Ett Adaptive Card, vad Workflows-flödet 'Post to a channel when a webhook request is received' tar emot."""
    link = f"https://{TICKET_HOST}/" if TICKET_HOST else ""
    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard", "version": "1.4",
                "body": [
                    {"type": "TextBlock", "size": "Medium", "weight": "Bolder", "text": f"Nytt ärende #{ticket.get('Id')}"},
                    {"type": "FactSet", "facts": [
                        {"title": "Från", "value": f"{ticket.get('Name', '')} <{ticket.get('Email', '')}>"},
                        {"title": "Mottaget", "value": str(ticket.get("Received", ""))},
                    ]},
                    {"type": "TextBlock", "wrap": True, "text": str(ticket.get("Message", ""))[:1000]},
                ],
                "actions": [{"type": "Action.OpenUrl", "title": "Öppna kön", "url": link}] if link else [],
            },
        }],
    }


def notify(ticket: dict) -> dict:
    ident = ticket.get("Id")
    subject = f"Nytt ärende #{ident} från {ticket.get('Name', '')}"
    body = (f"Ärende #{ident}\nFrån: {ticket.get('Name', '')} <{ticket.get('Email', '')}>\n"
            f"Mottaget: {ticket.get('Received', '')}\n\n{ticket.get('Message', '')}\n\n"
            + (f"Kön: https://{TICKET_HOST}/\n" if TICKET_HOST else ""))
    outcome: dict[str, object] = {"id": ident}
    for name, call in (
        ("mail", lambda: send_mail(subject, body)),
        ("teams", lambda: _post_json(TEAMS_WEBHOOK_URL, teams_card(ticket)) if TEAMS_WEBHOOK_URL else "no url"),
        ("slack", lambda: _post_json(SLACK_WEBHOOK_URL, {"text": subject + "\n" + body}) if SLACK_WEBHOOK_URL else "no url"),
    ):
        try:
            outcome[name] = call()
            if outcome[name] != "no url":
                _state["sent"] = int(_state["sent"]) + 1
        except Exception as error:  # noqa: BLE001 -- one channel failing must not stop the others
            outcome[name] = f"failed: {str(error)[:200]}"
            _state["failed"] = int(_state["failed"]) + 1
            log.warning("%s for #%s failed: %s", name, ident, error)
    _state["last"] = outcome
    log.info("notified %s", outcome)
    return outcome


@app.post("/ticket")
def ticket():
    """NocoDB:s webhook: {"type":"records.after.insert","data":{"rows":[...]}}"""
    payload = request.get_json(silent=True) or {}
    rows = (payload.get("data") or {}).get("rows") or []
    if not rows and payload.get("Id"):
        rows = [payload]
    outcomes = [notify(row) for row in rows]
    return jsonify(handled=len(outcomes), outcomes=outcomes)


@app.get("/health")
def health():
    try:
        sender, endpoint = _mail_setup()
    except Exception as error:  # noqa: BLE001
        return jsonify(status="degraded", error=str(error)[:200]), 503
    return jsonify(status="ok", sender=sender, endpoint=endpoint, to=SUPPORT_EMAIL,
                   teams=bool(TEAMS_WEBHOOK_URL), slack=bool(SLACK_WEBHOOK_URL),
                   sent=_state["sent"], failed=_state["failed"], last=_state["last"])
