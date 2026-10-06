"""Nordvik's notifier: takes each report off the queue and does what the portal never waits for.

A new report is grouped into an incident and gets a copy in the SharePoint list in Nordvik's
Microsoft 365. When it opens a new incident, the property's manager gets a mail; heating, water and
locks are mailed at once, to the on-call address too. A changed status follows to the copy. A report
a manager raises to urgent is mailed to on-call. A property handed over with an open urgent incident is
mailed to whoever takes it.

A message can arrive twice. Nothing is done twice: every step records that it is done.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Any
from zoneinfo import ZoneInfo

import azure.functions as func
import requests
from azure.communication.email import EmailClient
from azure.data.tables import TableClient, TableServiceClient, UpdateMode
from azure.identity import ClientAssertionCredential, ManagedIdentityCredential

app = func.FunctionApp()

URGENT = {"varme", "vatten", "las"}
CATEGORIES = {"varme": "Värme", "vatten": "Vatten", "las": "Lås", "el": "El", "ventilation": "Ventilation", "ovrigt": "Övrigt"}
STATUSES = {"mottagen": "Mottagen", "pagar": "Pågår", "atgardad": "Åtgärdad"}
WINDOW = timedelta(hours=2)
LOCAL = ZoneInfo("Europe/Stockholm")
ARM = "https://management.azure.com"
ARM_VERSION = "2023-04-01"
GRAPH = "https://graph.microsoft.com/v1.0"
TIMEOUT = 30

identity = ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"])


class Throttled(Exception):
    """Graph or Azure asked to wait. Raised so the queue gives the message back later."""


# --- the trigger --------------------------------------------------------------------------


@app.queue_trigger(arg_name="message", queue_name="nya-anmalningar", connection="Reports")
def handle(message: func.QueueMessage) -> None:
    body = json.loads(message.get_body().decode("utf-8"))
    kind = body.get("type")
    reports, properties = _tables()
    if kind == "ny":
        _new_report(reports, properties, body["pk"], body["rk"])
    elif kind == "status":
        _status(reports, body["pk"], body["rk"])
    elif kind == "akut":
        _raised(reports, properties, body["pk"], body["rk"])
    elif kind == "overlamning":
        _handover(reports, properties, body["property_id"], body["to_oid"])
    else:
        logging.warning("meddelande av okänd typ %r slängs", kind)


def _tables() -> tuple[TableClient, TableClient]:
    service = TableServiceClient(endpoint=os.environ["NORDVIK_TABLE_ENDPOINT"], credential=identity)
    return service.get_table_client("anmalningar"), service.get_table_client("fastigheter")


# --- a new report ---------------------------------------------------------------------------


def _new_report(reports: TableClient, properties: TableClient, pk: str, rk: str) -> None:
    report = reports.get_entity(pk, rk)
    building = _property(properties, report["property_id"])
    incident = _incident(reports, report)

    if not report.get("list_item_id"):
        item = _graph("POST", f"/sites/{_site()}/lists/{_list()}/items", {"fields": _fields(report, building, incident)})
        report["list_item_id"] = item["id"]
        reports.update_entity(report, mode=UpdateMode.MERGE)

    opened_it = incident["RowKey"] == report["RowKey"]
    if opened_it and not incident.get("notified"):
        _notify(properties, report, building, urgent=bool(incident.get("urgent")))
        incident["notified"] = True
        reports.update_entity(incident, mode=UpdateMode.MERGE)


def _incident(reports: TableClient, report: dict[str, Any]) -> dict[str, Any]:
    """The open incident this report belongs to, or the one it opens.

    A report for the same property and category within the window joins the open incident: a leak
    reported a hundred times is one incident, one copy count and one mail."""
    partition = f"h-{report['property_id']}"
    if report.get("incident_id"):
        return reports.get_entity(partition, report["incident_id"])

    received = _when(report["created"])
    query = f"PartitionKey eq '{partition}' and category eq '{report['category']}' and status eq 'oppen'"
    for incident in reports.query_entities(query):
        if received - _when(incident["last_report"]) <= WINDOW:
            incident["count"] = int(incident.get("count") or 1) + 1
            incident["last_report"] = report["created"]
            reports.update_entity(incident, mode=UpdateMode.MERGE)
            break
    else:
        incident = {
            "PartitionKey": partition,
            "RowKey": report["RowKey"],
            "category": report["category"],
            "opened": report["created"],
            "last_report": report["created"],
            "count": 1,
            "urgent": report["category"] in URGENT,
            "status": "oppen",
            "notified": False,
        }
        reports.upsert_entity(incident, mode=UpdateMode.MERGE)

    report["incident_id"] = incident["RowKey"]
    reports.update_entity(report, mode=UpdateMode.MERGE)
    return incident


def _fields(report: dict[str, Any], building: dict[str, Any], incident: dict[str, Any]) -> dict[str, Any]:
    """What the copy in the list holds: never the image, the description or the tenant's address."""
    return {
        "Title": report["title"],
        "Kategori": CATEGORIES.get(report["category"], report["category"]),
        "Fastighet": building.get("name") or report["property_id"],
        "Handelse": incident["RowKey"],
        "Mottagen": report["created"],
        "Status": STATUSES.get(report.get("status") or "mottagen", "Mottagen"),
        "Lank": _board_link(report),
    }


def _notify(properties: TableClient, report: dict[str, Any], building: dict[str, Any], *, urgent: bool) -> None:
    """The mail a new incident sends: to the manager who holds the property, and at once to the
    on-call address too when it is urgent. A property nobody holds mails nobody unless it is urgent:
    the report waits under Otilldelade on every manager's board."""
    to: list[str] = []
    manager = _manager_address(properties, building.get("manager_oid"))
    if manager:
        to.append(manager)
    if urgent:
        to.append(os.environ["NORDVIK_ONCALL_EMAIL"])
    if not to:
        return

    category = CATEGORIES.get(report["category"], report["category"])
    place = building.get("name") or report["property_id"]
    subject = f"{'AKUT: ' if urgent else 'Ny felanmälan: '}{category} i {place}"
    lines = [
        report["title"],
        "",
        report.get("description") or "",
        "",
        f"Fastighet: {place}, lägenhet {report.get('apartment') or 'okänd'}",
        f"Mottagen: {_local(report['created'])}",
        "",
        f"Öppna på tavlan: {_board_link(report)}",
    ]
    if not manager:
        lines.insert(0, "Ingen förvaltare har tagit fastigheten. Händelsen ligger under Otilldelade.\n")
    _mail(sorted(set(to)), subject, "\n".join(lines), urgent=urgent)


# --- what a manager does on the board -------------------------------------------------------


def _status(reports: TableClient, pk: str, rk: str) -> None:
    report = reports.get_entity(pk, rk)
    if report.get("list_item_id"):
        status = STATUSES.get(report.get("status") or "mottagen", "Mottagen")
        _graph("PATCH", f"/sites/{_site()}/lists/{_list()}/items/{report['list_item_id']}/fields", {"Status": status})
    if report.get("status") == "atgardad" and report.get("incident_id"):
        _close_if_done(reports, report)


def _close_if_done(reports: TableClient, report: dict[str, Any]) -> None:
    """An incident whose every report is done is closed: a later fault opens a new one, and a handover
    no longer counts it as an open urgent incident."""
    members = reports.query_entities(f"incident_id eq '{report['incident_id']}'")
    if all(member.get("status") == "atgardad" for member in members):
        incident = reports.get_entity(f"h-{report['property_id']}", report["incident_id"])
        incident["status"] = "stangd"
        reports.update_entity(incident, mode=UpdateMode.MERGE)


def _raised(reports: TableClient, properties: TableClient, pk: str, rk: str) -> None:
    report = reports.get_entity(pk, rk)
    if report.get("raised_notified"):
        return
    building = _property(properties, report["property_id"])
    place = building.get("name") or report["property_id"]
    text = (f"Förvaltaren har höjt en anmälan till akut.\n\n{report['title']}\n\n{report.get('description') or ''}\n\n"
            f"Fastighet: {place}, lägenhet {report.get('apartment') or 'okänd'}\n"
            f"Mottagen: {_local(report['created'])}\n\nÖppna på tavlan: {_board_link(report)}")
    _mail([os.environ["NORDVIK_ONCALL_EMAIL"]], f"AKUT: {report['title']} i {place}", text, urgent=True)
    report["raised_notified"] = True
    reports.update_entity(report, mode=UpdateMode.MERGE)


def _handover(reports: TableClient, properties: TableClient, property_id: str, to_oid: str) -> None:
    """A property handed to a colleague mails the colleague only if it has an open urgent incident:
    otherwise it shows on the board, and that is enough."""
    query = f"PartitionKey eq 'h-{property_id}' and status eq 'oppen' and urgent eq true"
    urgent = list(reports.query_entities(query))
    address = _manager_address(properties, to_oid)
    if not urgent or not address:
        return
    building = _property(properties, property_id)
    place = building.get("name") or property_id
    text = (f"Fastigheten {place} har lämnats över till dig. Den har {len(urgent)} öppen akut händelse"
            f"{'r' if len(urgent) > 1 else ''}.\n\nÖppna tavlan: {os.environ['NORDVIK_PORTAL_URL']}/tavla")
    _mail([address], f"AKUT: {place} är nu din", text, urgent=True)


# --- Nordvik's own data ------------------------------------------------------------------------


def _property(properties: TableClient, property_id: str) -> dict[str, Any]:
    try:
        return properties.get_entity("fastighet", property_id)
    except Exception:  # a property deleted since the report was made
        return {"RowKey": property_id}


def _manager_address(properties: TableClient, oid: str | None) -> str | None:
    if not oid:
        return None
    try:
        return properties.get_entity("forvaltare", oid).get("notify_email") or None
    except Exception:
        return None


def _board_link(report: dict[str, Any]) -> str:
    return f"{os.environ['NORDVIK_PORTAL_URL']}/tavla/{report['PartitionKey']}/{report['RowKey']}"


def _when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def _local(stamp: str) -> str:
    return _when(stamp).astimezone(LOCAL).strftime("%Y-%m-%d %H:%M")


# --- Microsoft Graph, across the tenant line with no secret -------------------------------------


def _site() -> str:
    return os.environ["NORDVIK_LIST_SITE"]


def _list() -> str:
    return os.environ["NORDVIK_LIST"]


@lru_cache(maxsize=1)
def _graph_credential() -> ClientAssertionCredential:
    """The identity's own token, traded at Nordvik's Microsoft 365 tenant for one as
    app-nordvik-m365, which trusts the identity. No secret exists for it."""
    return ClientAssertionCredential(
        tenant_id=os.environ["NORDVIK_M365_TENANT"],
        client_id=os.environ["NORDVIK_M365_APP_ID"],
        func=lambda: identity.get_token("api://AzureADTokenExchange/.default").token,
    )


def _graph(method: str, path: str, body: dict[str, Any]) -> dict[str, Any]:
    token = _graph_credential().get_token("https://graph.microsoft.com/.default").token
    response = requests.request(method, GRAPH + path, json=body, timeout=TIMEOUT,
                                headers={"Authorization": f"Bearer {token}"})
    if response.status_code in (429, 503):
        raise Throttled(f"Graph asked to wait {response.headers.get('Retry-After', '?')} s")
    response.raise_for_status()
    return response.json() if response.content else {}


# --- mail through Communication Services ---------------------------------------------------------


@lru_cache(maxsize=1)
def _mailer() -> tuple[EmailClient, str]:
    """The endpoint and the sender, read off the resources the profile deployed."""
    token = identity.get_token(f"{ARM}/.default").token
    headers = {"Authorization": f"Bearer {token}"}

    def read(resource_id: str) -> dict[str, Any]:
        response = requests.get(f"{ARM}{resource_id}?api-version={ARM_VERSION}", headers=headers, timeout=TIMEOUT)
        response.raise_for_status()
        return response.json()["properties"]

    host = read(os.environ["NORDVIK_ACS_ID"])["hostName"]
    domain = read(os.environ["NORDVIK_MAIL_DOMAIN_ID"])["mailFromSenderDomain"]
    return EmailClient(f"https://{host}", identity), f"DoNotReply@{domain}"


def _mail(to: list[str], subject: str, text: str, *, urgent: bool) -> None:
    client, sender = _mailer()
    message: dict[str, Any] = {
        "senderAddress": sender,
        "recipients": {"to": [{"address": address} for address in to]},
        "content": {"subject": subject, "plainText": text},
    }
    if urgent:
        message["headers"] = {"x-priority": "1"}
    client.begin_send(message).result()
    logging.info("mejl skickat: %s till %d mottagare", subject, len(to))
