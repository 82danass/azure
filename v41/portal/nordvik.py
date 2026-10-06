"""What the portal reaches in Azure, each as its managed identity: the tables, the image container,
the queue, and mail through Communication Services. No key and no connection string exists for any of
it: the storage account takes Entra tokens only, through its private endpoints."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Any, Iterable

import requests
from azure.communication.email import EmailClient
from azure.core.exceptions import ResourceNotFoundError
from azure.data.tables import TableClient, TableServiceClient, UpdateMode
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from azure.storage.queue import QueueClient, TextBase64EncodePolicy

ARM = "https://management.azure.com"
ARM_VERSION = "2023-04-01"
TIMEOUT = 30

CATEGORIES = {"varme": "Värme", "vatten": "Vatten", "las": "Lås", "el": "El", "ventilation": "Ventilation", "ovrigt": "Övrigt"}
URGENT = {"varme", "vatten", "las"}
STATUSES = {"mottagen": "Mottagen", "pagar": "Pågår", "atgardad": "Åtgärdad"}

CODE_MINUTES = 10
CODE_TRIES = 5
CODES_PER_ADDRESS = 3
CODES_PER_SENDER = 10

identity = ManagedIdentityCredential(client_id=os.environ.get("AZURE_CLIENT_ID"))


def account() -> str:
    return os.environ["NORDVIK_STORAGE_ACCOUNT"]


@lru_cache(maxsize=1)
def _tables() -> TableServiceClient:
    return TableServiceClient(endpoint=f"https://{account()}.table.core.windows.net", credential=identity)


def reports() -> TableClient:
    return _tables().get_table_client("anmalningar")


def properties() -> TableClient:
    return _tables().get_table_client("fastigheter")


@lru_cache(maxsize=1)
def _blobs() -> BlobServiceClient:
    return BlobServiceClient(account_url=f"https://{account()}.blob.core.windows.net", credential=identity)


@lru_cache(maxsize=1)
def _queue() -> QueueClient:
    # Base64, as the Function's queue trigger reads it by default.
    return QueueClient(account_url=f"https://{account()}.queue.core.windows.net", queue_name="nya-anmalningar",
                       credential=identity, message_encode_policy=TextBase64EncodePolicy())


def enqueue(message: dict[str, Any]) -> None:
    _queue().send_message(json.dumps(message))


# --- who a tenant is: an address they have proven ------------------------------------------------


def address_hash(address: str) -> str:
    return hashlib.sha256(address.strip().lower().encode("utf-8")).hexdigest()[:32]


def valid_address(address: str) -> bool:
    return bool(re.fullmatch(r"[^@\s]{1,64}@[^@\s]{1,255}\.[A-Za-z]{2,}", address.strip()))


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(moment: datetime) -> str:
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def _within_rate(key: str, limit: int) -> bool:
    """Count one more code against this key for this hour; False when the hour's limit is reached."""
    hour = _now().strftime("%Y%m%d%H")
    row = f"{key}-{hour}"
    table = reports()
    try:
        entity = table.get_entity("kodtakt", row)
    except ResourceNotFoundError:
        entity = {"PartitionKey": "kodtakt", "RowKey": row, "count": 0}
    if int(entity["count"]) >= limit:
        return False
    entity["count"] = int(entity["count"]) + 1
    table.upsert_entity(entity, mode=UpdateMode.REPLACE)
    return True


def send_code(address: str, sender_ip: str) -> str | None:
    """Mail a six-digit code to the address. None when it went out; the reason when it did not."""
    who = address_hash(address)
    ip = hashlib.sha256(sender_ip.encode("utf-8")).hexdigest()[:16]
    if not _within_rate(f"e-{who}", CODES_PER_ADDRESS):
        return "För många koder till den adressen den senaste timmen. Försök igen senare."
    if not _within_rate(f"i-{ip}", CODES_PER_SENDER):
        return "För många koder härifrån den senaste timmen. Försök igen senare."
    code = f"{secrets.randbelow(10 ** 6):06d}"
    reports().upsert_entity({
        "PartitionKey": "kod", "RowKey": who,
        "code_hash": hashlib.sha256(f"{code}{who}".encode("utf-8")).hexdigest(),
        "expires": _stamp(_now() + timedelta(minutes=CODE_MINUTES)), "attempts": 0,
    }, mode=UpdateMode.REPLACE)
    mail([address], f"Din kod till Nordviks felanmälan: {code}",
         f"Din kod är {code}.\n\nSkriv in den i formuläret för att skicka anmälan. Koden gäller i "
         f"{CODE_MINUTES} minuter.\n\nHar du inte bett om en kod kan du bortse från det här mejlet.")
    return None


def check_code(address: str, code: str) -> str | None:
    """None when the code is right, and it is then used up; otherwise why it is not."""
    who = address_hash(address)
    table = reports()
    try:
        entity = table.get_entity("kod", who)
    except ResourceNotFoundError:
        return "Be om en kod först."
    if datetime.fromisoformat(entity["expires"].replace("Z", "+00:00")) < _now():
        table.delete_entity("kod", who)
        return "Koden har gått ut. Be om en ny."
    if int(entity["attempts"]) >= CODE_TRIES:
        table.delete_entity("kod", who)
        return "För många fel försök. Be om en ny kod."
    if not secrets.compare_digest(entity["code_hash"], hashlib.sha256(f"{code.strip()}{who}".encode("utf-8")).hexdigest()):
        entity["attempts"] = int(entity["attempts"]) + 1
        table.update_entity(entity, mode=UpdateMode.MERGE)
        return "Fel kod."
    table.delete_entity("kod", who)
    return None


# --- reports ----------------------------------------------------------------------------------------


IMAGE_TYPES = {b"\xff\xd8\xff": ("jpg", "image/jpeg"), b"\x89PNG": ("png", "image/png"),
               b"RIFF": ("webp", "image/webp")}


def image_kind(head: bytes) -> tuple[str, str] | None:
    for magic, kind in IMAGE_TYPES.items():
        if head.startswith(magic):
            return kind
    if head[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1"):
        return "heic", "image/heic"
    return None


def save_report(address: str, fields: dict[str, str], image: bytes, kind: tuple[str, str]) -> dict[str, Any]:
    created = _now()
    report_id = f"{created.strftime('%Y%m%d%H%M%S')}-{secrets.token_hex(3)}"
    extension, content_type = kind
    blob = f"{report_id}.{extension}"
    _blobs().get_blob_client("bilder", blob).upload_blob(image, content_settings=ContentSettings(content_type=content_type))
    entity = {
        "PartitionKey": f"t-{address_hash(address)}", "RowKey": report_id,
        "title": fields["title"], "description": fields["description"], "category": fields["category"],
        "property_id": fields["property_id"], "apartment": fields["apartment"], "image": blob,
        "email": address.strip(), "created": _stamp(created), "status": "mottagen",
        "priority": "akut" if fields["category"] in URGENT else "normal",
    }
    reports().create_entity(entity)
    enqueue({"type": "ny", "pk": entity["PartitionKey"], "rk": report_id})
    return entity


def tenant_reports(who: str) -> list[dict[str, Any]]:
    found = reports().query_entities(f"PartitionKey eq 't-{who}'")
    return sorted(found, key=lambda e: e["RowKey"], reverse=True)


def all_reports() -> list[dict[str, Any]]:
    # Every report is under a t- partition. Nordvik's volume, some 25 000 a year, makes a scan of
    # those partitions cheap; a larger one would keep an index row per property instead.
    found = reports().query_entities("PartitionKey ge 't-' and PartitionKey lt 't.'")
    return sorted(found, key=lambda e: e["RowKey"], reverse=True)


def report(pk: str, rk: str) -> dict[str, Any] | None:
    try:
        return reports().get_entity(pk, rk)
    except ResourceNotFoundError:
        return None


def update_report(entity: dict[str, Any]) -> None:
    reports().update_entity(entity, mode=UpdateMode.MERGE)


def image(name: str) -> tuple[bytes, str]:
    client = _blobs().get_blob_client("bilder", name)
    data = client.download_blob()
    return data.readall(), data.properties.content_settings.content_type or "application/octet-stream"


# --- properties and managers ---------------------------------------------------------------------


def all_properties() -> list[dict[str, Any]]:
    return sorted(properties().query_entities("PartitionKey eq 'fastighet'"), key=lambda e: e.get("name", ""))


def property_slug(name: str) -> str:
    plain = name.lower().translate(str.maketrans({"å": "a", "ä": "a", "ö": "o", "é": "e"}))
    return re.sub(r"[^a-z0-9]+", "-", plain).strip("-")[:60] or secrets.token_hex(4)


def save_property(entity: dict[str, Any]) -> None:
    properties().upsert_entity(entity, mode=UpdateMode.MERGE)


def managers() -> list[dict[str, Any]]:
    return sorted(properties().query_entities("PartitionKey eq 'forvaltare'"), key=lambda e: e.get("name", ""))


def manager(oid: str) -> dict[str, Any] | None:
    try:
        return properties().get_entity("forvaltare", oid)
    except ResourceNotFoundError:
        return None


def save_manager(oid: str, name: str, notify_email: str | None = None) -> None:
    entity: dict[str, Any] = {"PartitionKey": "forvaltare", "RowKey": oid, "name": name}
    if notify_email is not None:
        entity["notify_email"] = notify_email
    properties().upsert_entity(entity, mode=UpdateMode.MERGE)


def healthy() -> bool:
    try:
        next(iter(properties().query_entities("PartitionKey eq 'fastighet'", results_per_page=1)), None)
        return True
    except Exception:
        return False


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


def mail(to: Iterable[str], subject: str, text: str) -> None:
    client, sender = _mailer()
    client.begin_send({
        "senderAddress": sender,
        "recipients": {"to": [{"address": address} for address in to]},
        "content": {"subject": subject, "plainText": text},
    }).result()
