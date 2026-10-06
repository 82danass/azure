"""What the finance site reads, top down: the billing profile, the subscription, the resource groups,
the cost day by day, the resources with their tags, and the cost per department and per property.

Cost, budgets, alerts and billing are read as app-nordvik-kostnad, which trusts this site's managed
identity: the identity's own token is traded for one as the app, and no secret exists. The resources
and the report counts are read as the identity itself, which holds Reader on its own group and Table
Data Reader on the reports. Nothing here writes. A level Azure refuses is shown as not available, so one
missing grant does not take the page down.
"""

from __future__ import annotations

import os
import time
from collections import Counter
from datetime import datetime, timezone
from typing import Any, Callable

import requests
from azure.data.tables import TableServiceClient
from azure.identity import ClientAssertionCredential, ManagedIdentityCredential

ARM = "https://management.azure.com"
COST_VERSION = "2023-11-01"
CONSUMPTION_VERSION = "2023-11-01"
CREDITS_VERSION = "2023-05-01"
BILLING_VERSION = "2024-04-01"
RESOURCES_VERSION = "2021-04-01"
TIMEOUT = 60
CACHE_SECONDS = 300

identity = ManagedIdentityCredential(client_id=os.environ.get("AZURE_CLIENT_ID"))
SUBSCRIPTION = os.environ.get("NORDVIK_SUBSCRIPTION_ID", "")
SCOPE = f"/subscriptions/{SUBSCRIPTION}"

_cache: dict[str, tuple[float, Any]] = {}


def _cached(key: str, read: Callable[[], Any]) -> Any:
    """Cost Management allows few calls a minute per scope; five minutes old is fresh enough for cost
    data Azure itself only updates a few times a day."""
    found = _cache.get(key)
    if found and time.monotonic() - found[0] < CACHE_SECONDS:
        return found[1]
    try:
        value = read()
    except Exception as error:  # a refused level is shown as such, never a broken page
        value = {"unavailable": _reason(error)}
    _cache[key] = (time.monotonic(), value)
    return value


def _reason(error: Exception) -> str:
    if isinstance(error, requests.HTTPError) and error.response is not None:
        try:
            return error.response.json().get("error", {}).get("message", "")[:200] or str(error)
        except ValueError:
            return str(error)
    return str(error)[:200]


def _cost_token() -> str:
    credential = ClientAssertionCredential(
        tenant_id=os.environ["NORDVIK_TENANT_ID"],
        client_id=os.environ["NORDVIK_COST_APP_ID"],
        func=lambda: identity.get_token("api://AzureADTokenExchange/.default").token,
    )
    return credential.get_token(f"{ARM}/.default").token


def _own_token() -> str:
    return identity.get_token(f"{ARM}/.default").token


def _call(method: str, path: str, version: str, body: dict[str, Any] | None = None, *, own: bool = False,
          extra: str = "") -> dict[str, Any]:
    token = _own_token() if own else _cost_token()
    separator = "&" if "?" in path else "?"
    response = requests.request(method, f"{ARM}{path}{separator}api-version={version}{extra}", json=body,
                                headers={"Authorization": f"Bearer {token}"}, timeout=TIMEOUT)
    response.raise_for_status()
    return response.json() if response.content else {}


def _query(scope: str, grouping: list[dict[str, str]] | None = None, granularity: str = "None") -> list[dict[str, Any]]:
    body: dict[str, Any] = {"type": "ActualCost", "timeframe": "MonthToDate",
                            "dataset": {"granularity": granularity,
                                        "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}}}}
    if grouping:
        body["dataset"]["grouping"] = grouping
    answer = _call("POST", f"{scope}/providers/Microsoft.CostManagement/query", COST_VERSION, body)["properties"]
    names = [column["name"] for column in answer["columns"]]
    return [dict(zip(names, row)) for row in answer["rows"]]


# --- the levels ----------------------------------------------------------------------------------


def billing() -> dict[str, Any]:
    def read() -> dict[str, Any]:
        profile = _call("GET", f"{SCOPE}/providers/Microsoft.Billing/billingProperty/default", BILLING_VERSION)["properties"]
        path = profile["billingProfileId"]
        rows = _query(path, [{"type": "Dimension", "name": "SubscriptionName"}])
        out: dict[str, Any] = {"name": profile.get("billingProfileDisplayName"), "subscriptions": rows}
        try:
            summary = _call("GET", f"{path}/providers/Microsoft.Consumption/credits/balanceSummary", CREDITS_VERSION)
            balance = summary["properties"]["balanceSummary"]
            out["credit"] = balance.get("estimatedBalanceInBillingCurrency") or balance.get("estimatedBalance")
        except Exception as error:
            out["credit"] = {"unavailable": _reason(error)}
        try:
            today = datetime.now(timezone.utc).date()
            invoices = _call("GET", f"{path}/invoices", BILLING_VERSION,
                             extra=f"&periodStartDate={today.replace(year=today.year - 1)}&periodEndDate={today}")
            out["invoices"] = [entry["properties"] for entry in invoices.get("value", [])]
        except Exception as error:
            out["invoices"] = {"unavailable": _reason(error)}
        return out
    return _cached("billing", read)


def subscription() -> dict[str, Any]:
    def read() -> dict[str, Any]:
        budgets = _call("GET", f"{SCOPE}/providers/Microsoft.Consumption/budgets", CONSUMPTION_VERSION)["value"]
        alerts = _call("GET", f"{SCOPE}/providers/Microsoft.CostManagement/alerts", COST_VERSION)["value"]
        return {"budgets": [_budget(entry) for entry in budgets], "alerts": [_alert(entry) for entry in alerts]}
    return _cached("subscription", read)


def groups() -> list[dict[str, Any]]:
    """Each resource group's cost this month, and its own budget where it has one."""
    def read() -> list[dict[str, Any]]:
        rows = _query(SCOPE, [{"type": "Dimension", "name": "ResourceGroupName"}])
        out = []
        for row in sorted(rows, key=lambda r: -float(r["Cost"])):
            name = row["ResourceGroupName"]
            try:
                budgets = _call("GET", f"{SCOPE}/resourceGroups/{name}/providers/Microsoft.Consumption/budgets",
                                CONSUMPTION_VERSION)["value"]
            except Exception:
                budgets = []
            out.append({"name": name, "cost": float(row["Cost"]), "currency": row.get("Currency"),
                        "budgets": [_budget(entry) for entry in budgets]})
        return out
    return _cached("groups", read)


def daily() -> list[dict[str, Any]]:
    def read() -> list[dict[str, Any]]:
        rows = _query(SCOPE, granularity="Daily")
        return sorted(({"day": str(row["UsageDate"]), "cost": float(row["Cost"]), "currency": row.get("Currency")}
                       for row in rows), key=lambda r: r["day"])
    return _cached("daily", read)


def by_tag(tag: str) -> list[dict[str, Any]]:
    def read() -> list[dict[str, Any]]:
        rows = _query(SCOPE, [{"type": "TagKey", "name": tag}])
        found: Counter[str] = Counter()
        for row in rows:
            found[str(row.get("TagValue") or "utan tagg")] += float(row["Cost"])
        return [{"value": key, "cost": value} for key, value in found.most_common()]
    return _cached(f"tag-{tag}", read)


def resources() -> list[dict[str, Any]]:
    """The resources of the group this site can read, with their tags and their cost this month."""
    def read() -> list[dict[str, Any]]:
        readable = _call("GET", f"{SCOPE}/resourcegroups", RESOURCES_VERSION, own=True)["value"]
        cost = {str(row["ResourceId"]).lower(): float(row["Cost"])
                for row in _query(SCOPE, [{"type": "Dimension", "name": "ResourceId"}])}
        out = []
        for group in readable:
            listed = _call("GET", f"{SCOPE}/resourceGroups/{group['name']}/resources", RESOURCES_VERSION, own=True)["value"]
            for entry in listed:
                out.append({"name": entry["name"], "type": entry["type"], "group": group["name"],
                            "tags": entry.get("tags") or {}, "cost": cost.get(entry["id"].lower(), 0.0)})
        return sorted(out, key=lambda r: -r["cost"])
    return _cached("resources", read)


def per_property(total: float) -> list[dict[str, Any]]:
    """Tags cannot split a shared environment, so the common cost is shared by each property's share
    of the reports."""
    def read() -> list[dict[str, Any]]:
        tables = TableServiceClient(endpoint=f"https://{os.environ['NORDVIK_STORAGE_ACCOUNT']}.table.core.windows.net",
                                    credential=identity)
        names = {e["RowKey"]: e.get("name", e["RowKey"]) for e in
                 tables.get_table_client("fastigheter").query_entities("PartitionKey eq 'fastighet'")}
        counts: Counter[str] = Counter(e["property_id"] for e in tables.get_table_client("anmalningar").query_entities(
            "PartitionKey ge 't-' and PartitionKey lt 't.'", select=["property_id"]))
        reported = sum(counts.values())
        return [{"property": names.get(key, key), "reports": count, "share": count / reported,
                 "cost": total * count / reported} for key, count in counts.most_common()] if reported else []
    return _cached("per-property", read)


def _budget(entry: dict[str, Any]) -> dict[str, Any]:
    properties = entry.get("properties") or {}
    spent = (properties.get("currentSpend") or {})
    forecast = (properties.get("forecastSpend") or {})
    thresholds = sorted({float(rule.get("threshold") or 0) for rule in (properties.get("notifications") or {}).values()})
    return {"name": entry.get("name"), "amount": float(properties.get("amount") or 0), "grain": properties.get("timeGrain"),
            "spent": float(spent.get("amount") or 0), "forecast": float(forecast.get("amount") or 0) if forecast else None,
            "unit": spent.get("unit") or "", "thresholds": thresholds}


def _alert(entry: dict[str, Any]) -> dict[str, Any]:
    properties = entry.get("properties") or {}
    details = properties.get("details") or {}
    return {"type": (properties.get("definition") or {}).get("type"), "status": properties.get("status"),
            "source": str(properties.get("costEntityId") or "").rsplit("/", 1)[-1],
            "threshold": details.get("threshold"), "spent": details.get("currentSpend"),
            "since": properties.get("creationTime")}
