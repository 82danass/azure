"""Nordvik's tenant portal.

A tenant reports a fault without an account: the address they confirm with a one-time code is who they
are, and a signed link brings them to their own reports. Staff sign in through Entra ID: managers work on
the board, take responsibility for properties and judge each report; finance reads. The sign-in holds no
secret: the registration trusts the portal's managed identity, whose token is the client assertion.
"""

from __future__ import annotations

import os
from functools import wraps
from typing import Any, Callable

import msal
from flask import Flask, Response, abort, jsonify, redirect, render_template, request, session, url_for
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from werkzeug.middleware.proxy_fix import ProxyFix

import nordvik

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
app.config.update(
    SECRET_KEY=os.environ["NORDVIK_SESSION_KEY"],
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PREFERRED_URL_SCHEME="https",
    MAX_CONTENT_LENGTH=11 * 1024 * 1024,
)

TENANT = os.environ["NORDVIK_TENANT_ID"]
CLIENT = os.environ["NORDVIK_SIGNIN_CLIENT_ID"]
PUBLIC = os.environ["NORDVIK_PUBLIC_URL"].rstrip("/")
MANAGERS = os.environ["NORDVIK_GROUP_FORVALTARE"]
FINANCE = os.environ["NORDVIK_GROUP_EKONOMI"]
LINK_DAYS = 30
MAX_IMAGE = 10 * 1024 * 1024

links = URLSafeTimedSerializer(app.config["SECRET_KEY"], salt="mina")


@app.context_processor
def shared() -> dict[str, Any]:
    return {"user": session.get("user"), "categories": nordvik.CATEGORIES, "statuses": nordvik.STATUSES}


@app.get("/health")
def health() -> Response:
    ok = nordvik.healthy()
    return jsonify(status="ok" if ok else "degraded"), (200 if ok else 503)


# --- the tenant: a report without an account ------------------------------------------------------


@app.get("/")
def form() -> str:
    return render_template("form.html", properties=nordvik.all_properties(), fields={}, error=None)


@app.post("/kod")
def code() -> Response:
    address = request.form.get("email", "").strip()
    if not nordvik.valid_address(address):
        return jsonify(ok=False, message="Skriv en giltig e-postadress."), 400
    refused = nordvik.send_code(address, request.remote_addr or "okänd")
    if refused:
        return jsonify(ok=False, message=refused), 429
    return jsonify(ok=True, message=f"En kod är skickad till {address}. Den gäller i {nordvik.CODE_MINUTES} minuter.")


@app.post("/anmal")
def report() -> str | tuple[str, int]:
    fields = {key: request.form.get(key, "").strip() for key in
              ("title", "description", "category", "property_id", "apartment", "email", "code")}
    known = {entry["RowKey"] for entry in nordvik.all_properties()}

    def again(message: str) -> tuple[str, int]:
        return render_template("form.html", properties=nordvik.all_properties(), fields=fields, error=message), 400

    if not fields["title"] or not fields["description"]:
        return again("Skriv en rubrik och en beskrivning.")
    if fields["category"] not in nordvik.CATEGORIES:
        return again("Välj vad som är trasigt.")
    if fields["property_id"] not in known:
        return again("Välj fastighet.")
    if not nordvik.valid_address(fields["email"]):
        return again("Skriv en giltig e-postadress.")
    upload = request.files.get("image")
    data = upload.read(MAX_IMAGE + 1) if upload else b""
    if not data:
        return again("Lägg till en bild på felet.")
    if len(data) > MAX_IMAGE:
        return again("Bilden är större än 10 MB.")
    kind = nordvik.image_kind(data[:16])
    if kind is None:
        return again("Bilden ska vara JPEG, PNG, WebP eller HEIC.")
    refused = nordvik.check_code(fields["email"], fields["code"])
    if refused:
        return again(refused)

    entity = nordvik.save_report(fields["email"], fields, data, kind)
    link = _tenant_link(fields["email"])
    nordvik.mail([fields["email"]], f"Din felanmälan är mottagen: {fields['title']}",
                 f"Tack. Vi har tagit emot din felanmälan \"{fields['title']}\".\n\n"
                 f"Här följer du dina anmälningar och ser när något händer:\n{link}\n\n"
                 f"Länken gäller i {LINK_DAYS} dagar. En ny får du med en ny kod på {PUBLIC}/mina.")
    return render_template("thanks.html", report=entity, link=link)


def _tenant_link(address: str) -> str:
    return f"{PUBLIC}/mina/{links.dumps(nordvik.address_hash(address))}"


@app.get("/mina/<token>")
def mine(token: str) -> str | tuple[str, int]:
    try:
        who = links.loads(token, max_age=LINK_DAYS * 24 * 3600)
    except SignatureExpired:
        return render_template("mina_ny.html", error="Länken har gått ut. Be om en ny nedan.", sent=False), 410
    except BadSignature:
        abort(404)
    names = {entry["RowKey"]: entry.get("name", entry["RowKey"]) for entry in nordvik.all_properties()}
    return render_template("mina.html", reports=nordvik.tenant_reports(who), names=names)


@app.route("/mina", methods=["GET", "POST"])
def new_link() -> str | tuple[str, int]:
    if request.method == "GET":
        return render_template("mina_ny.html", error=None, sent=False)
    address = request.form.get("email", "").strip()
    refused = nordvik.check_code(address, request.form.get("code", "")) if nordvik.valid_address(address) else "Skriv en giltig e-postadress."
    if refused:
        return render_template("mina_ny.html", error=refused, sent=False), 400
    nordvik.mail([address], "Din länk till dina felanmälningar",
                 f"Här följer du dina anmälningar:\n{_tenant_link(address)}\n\nLänken gäller i {LINK_DAYS} dagar.")
    return render_template("mina_ny.html", error=None, sent=True)


# --- staff: sign-in through Entra ID, no secret ---------------------------------------------------


def _signin() -> msal.ConfidentialClientApplication:
    # The client credential is the portal identity's own token for the token exchange audience: the
    # registration trusts the identity, so no secret exists to hold or leak.
    assertion = nordvik.identity.get_token("api://AzureADTokenExchange/.default").token
    return msal.ConfidentialClientApplication(
        CLIENT, authority=f"https://login.microsoftonline.com/{TENANT}",
        client_credential={"client_assertion": assertion},
    )


@app.get("/login")
def login() -> Response:
    flow = _signin().initiate_auth_code_flow([], redirect_uri=f"{PUBLIC}/auth/callback")
    session["flow"] = flow
    session["after"] = request.args.get("next") or url_for("board")
    return redirect(flow["auth_uri"])


@app.get("/auth/callback")
def callback() -> Response:
    flow = session.pop("flow", None)
    if not flow:
        return redirect(url_for("login"))
    result = _signin().acquire_token_by_auth_code_flow(flow, request.args.to_dict())
    if "error" in result:
        abort(401)
    claims = result["id_token_claims"]
    groups = set(claims.get("groups") or [])
    role = "forvaltare" if MANAGERS in groups else "ekonomi" if FINANCE in groups else None
    if role is None:
        session.clear()
        return render_template("refused.html"), 403
    session["user"] = {"oid": claims["oid"], "name": claims.get("name") or claims.get("preferred_username"),
                       "email": claims.get("email") or claims.get("preferred_username"), "role": role}
    if role == "forvaltare" and nordvik.manager(claims["oid"]) is None:
        nordvik.save_manager(claims["oid"], session["user"]["name"], session["user"]["email"])
    return redirect(session.pop("after", url_for("board")))


@app.get("/logout")
def logout() -> Response:
    session.clear()
    return redirect(f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/logout?post_logout_redirect_uri={PUBLIC}/")


def staff(*roles: str) -> Callable:
    def decorate(view: Callable) -> Callable:
        @wraps(view)
        def guarded(*args: Any, **kwargs: Any) -> Any:
            user = session.get("user")
            if not user:
                return redirect(url_for("login", next=request.path))
            if user["role"] not in roles:
                return render_template("refused.html"), 403
            return view(*args, **kwargs)
        return guarded
    return decorate


# --- the board ------------------------------------------------------------------------------------


@app.get("/tavla")
@staff("forvaltare", "ekonomi")
def board() -> str:
    """A manager's own properties and the ones nobody holds, grouped by incident; finance reads all."""
    user = session["user"]
    buildings = {entry["RowKey"]: entry for entry in nordvik.all_properties()}
    mine = {key for key, entry in buildings.items() if entry.get("manager_oid") == user["oid"]}
    unassigned = {key for key, entry in buildings.items() if not entry.get("manager_oid")}
    view = request.args.get("visa", "mina" if user["role"] == "forvaltare" else "alla")
    wanted = {"mina": mine, "otilldelade": unassigned}.get(view)

    incidents: dict[str, dict[str, Any]] = {}
    for entry in nordvik.all_reports():
        if wanted is not None and entry["property_id"] not in wanted:
            continue
        key = entry.get("incident_id") or entry["RowKey"]
        group = incidents.setdefault(key, {"reports": [], "property": buildings.get(entry["property_id"], {}),
                                           "category": entry["category"], "urgent": False, "open": False})
        group["reports"].append(entry)
        group["urgent"] = group["urgent"] or entry.get("priority") == "akut"
        group["open"] = group["open"] or entry.get("status") != "atgardad"
    # Open before closed, urgent before normal; within each, newest first, the order the reports came in.
    ordered = sorted(incidents.values(), key=lambda g: (not g["open"], not g["urgent"]))
    return render_template("board.html", incidents=ordered, view=view, mine=len(mine), unassigned=len(unassigned))


@app.get("/tavla/<pk>/<rk>")
@staff("forvaltare", "ekonomi")
def detail(pk: str, rk: str) -> str:
    entry = nordvik.report(pk, rk) or abort(404)
    building = next((b for b in nordvik.all_properties() if b["RowKey"] == entry["property_id"]), {})
    return render_template("report.html", report=entry, building=building)


@app.get("/bild/<pk>/<rk>")
@staff("forvaltare", "ekonomi")
def picture(pk: str, rk: str) -> Response:
    entry = nordvik.report(pk, rk) or abort(404)
    data, content_type = nordvik.image(entry["image"])
    return Response(data, mimetype=content_type, headers={"Cache-Control": "private, max-age=300"})


@app.post("/tavla/<pk>/<rk>/status")
@staff("forvaltare")
def set_status(pk: str, rk: str) -> Response:
    entry = nordvik.report(pk, rk) or abort(404)
    status = request.form.get("status", "")
    if status in nordvik.STATUSES and status != entry.get("status"):
        entry["status"] = status
        nordvik.update_report(entry)
        nordvik.enqueue({"type": "status", "pk": pk, "rk": rk})
    return redirect(url_for("detail", pk=pk, rk=rk))


@app.post("/tavla/<pk>/<rk>/prioritet")
@staff("forvaltare")
def set_priority(pk: str, rk: str) -> Response:
    """The manager judges: lowering takes a report off the urgent path; raising one sends on-call a mail."""
    entry = nordvik.report(pk, rk) or abort(404)
    priority = request.form.get("priority", "")
    if priority in ("normal", "akut") and priority != entry.get("priority"):
        entry["priority"] = priority
        nordvik.update_report(entry)
        if priority == "akut":
            nordvik.enqueue({"type": "akut", "pk": pk, "rk": rk, "by": session["user"]["oid"]})
    return redirect(url_for("detail", pk=pk, rk=rk))


# --- properties: managers take responsibility themselves ------------------------------------------


@app.get("/fastigheter")
@staff("forvaltare")
def buildings() -> str:
    names = {m["RowKey"]: m.get("name", m["RowKey"]) for m in nordvik.managers()}
    return render_template("properties.html", properties=nordvik.all_properties(), managers=nordvik.managers(), names=names)


@app.post("/fastigheter")
@staff("forvaltare")
def add_building() -> Response:
    name = request.form.get("name", "").strip()
    if name:
        nordvik.save_property({"PartitionKey": "fastighet", "RowKey": nordvik.property_slug(name), "name": name,
                               "address": request.form.get("address", "").strip(), "manager_oid": ""})
    return redirect(url_for("buildings"))


@app.post("/fastigheter/<key>")
@staff("forvaltare")
def change_building(key: str) -> Response:
    """Take, leave or hand over. Taking mails nobody: the manager took it. Handing over mails the
    colleague only when the property has an open urgent incident; the Function decides that."""
    user = session["user"]
    entry = next((b for b in nordvik.all_properties() if b["RowKey"] == key), None) or abort(404)
    action = request.form.get("action")
    if action == "ta":
        entry["manager_oid"], entry["manager_name"] = user["oid"], user["name"]
    elif action == "lamna" and entry.get("manager_oid") == user["oid"]:
        entry["manager_oid"], entry["manager_name"] = "", ""
    elif action == "overlamna":
        colleague = nordvik.manager(request.form.get("to", "")) or abort(400)
        entry["manager_oid"], entry["manager_name"] = colleague["RowKey"], colleague.get("name", "")
        nordvik.enqueue({"type": "overlamning", "property_id": key, "to_oid": colleague["RowKey"]})
    else:
        abort(400)
    nordvik.save_property(entry)
    return redirect(url_for("buildings"))


@app.route("/installningar", methods=["GET", "POST"])
@staff("forvaltare")
def settings() -> str:
    user = session["user"]
    if request.method == "POST":
        address = request.form.get("notify_email", "").strip()
        if nordvik.valid_address(address):
            nordvik.save_manager(user["oid"], user["name"], address)
    current = nordvik.manager(user["oid"]) or {}
    return render_template("settings.html", notify_email=current.get("notify_email") or user["email"])
