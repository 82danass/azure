"""Nordvik's finance site: what hosting the portal costs, read top down, for finance only.

Finance signs in through Entra ID; only members of the finance group get in. The sign-in holds no
secret: the registration trusts the site's managed identity, whose token is the client assertion.
Nothing on any page writes.
"""

from __future__ import annotations

import os
from functools import wraps
from typing import Any, Callable

import msal
from flask import Flask, Response, abort, jsonify, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

import cost

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
app.config.update(
    SECRET_KEY=os.environ["NORDVIK_SESSION_KEY"],
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PREFERRED_URL_SCHEME="https",
)

TENANT = os.environ["NORDVIK_TENANT_ID"]
CLIENT = os.environ["NORDVIK_SIGNIN_CLIENT_ID"]
PUBLIC = os.environ["NORDVIK_PUBLIC_URL"].rstrip("/")
FINANCE = os.environ["NORDVIK_GROUP_EKONOMI"]


@app.context_processor
def shared() -> dict[str, Any]:
    return {"user": session.get("user")}


@app.get("/health")
def health() -> Response:
    return jsonify(status="ok")


def _signin() -> msal.ConfidentialClientApplication:
    assertion = cost.identity.get_token("api://AzureADTokenExchange/.default").token
    return msal.ConfidentialClientApplication(
        CLIENT, authority=f"https://login.microsoftonline.com/{TENANT}",
        client_credential={"client_assertion": assertion},
    )


@app.get("/login")
def login() -> Response:
    flow = _signin().initiate_auth_code_flow([], redirect_uri=f"{PUBLIC}/auth/callback")
    session["flow"] = flow
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
    if FINANCE not in set(claims.get("groups") or []):
        session.clear()
        return render_template("refused.html"), 403
    session["user"] = {"oid": claims["oid"], "name": claims.get("name") or claims.get("preferred_username")}
    return redirect(url_for("overview"))


@app.get("/logout")
def logout() -> Response:
    session.clear()
    return redirect(f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/logout?post_logout_redirect_uri={PUBLIC}/")


def finance(view: Callable) -> Callable:
    @wraps(view)
    def guarded(*args: Any, **kwargs: Any) -> Any:
        if not session.get("user"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return guarded


@app.get("/")
@finance
def overview() -> str:
    groups = cost.groups()
    total = sum(g["cost"] for g in groups if g["name"].lower().startswith("rg-nordvik")) if isinstance(groups, list) else 0.0
    return render_template(
        "overview.html",
        billing=cost.billing(), subscription=cost.subscription(), groups=groups, daily=cost.daily(),
        resources=cost.resources(), departments=cost.by_tag("avdelning"), properties=cost.per_property(total),
        total=total,
    )
