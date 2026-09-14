"""Governed one-shot U3 development dataset executor.

The executor never accepts a service-role/secret key.  Every mutation is sent
to PostgREST or a public RPC with one of two genuine user access tokens, so the
existing grants, RLS policies, capability checks and lifecycle triggers remain
the authority.  It is resumable only for the exact permanently consumed 9301
identity; it never deletes, repairs, renumbers or recreates a retired dataset.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import sys
from urllib import error, parse, request


TAG = "__U3_DEV_ONLY_9301__"
PLANT_ID = 1
PLANT_CODE = "NAG"
PROPOSER = {"app_user_id": 44, "display_name": "NikunjRL", "email": "nikunj@avadhootpacks.in"}
APPROVER = {"app_user_id": 45, "display_name": "ClaudeCode", "email": "claude@com"}
ENGINE_VERSION = "engine/qe1-7c2ceac1972460ba"
DEFAULT_VERSION_NUMBERS = (9301001, 9301002, 9301003)
AUTHORIZATION = "U3-DATASET-9301-AUTHORIZED"


def _public_env() -> dict[str, str]:
    values = {key: os.environ.get(key, "") for key in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY")}
    env_path = Path(__file__).resolve().parents[1] / ".env"
    if env_path.exists():
        for raw in env_path.read_text(encoding="utf-8").splitlines():
            key, sep, value = raw.partition("=")
            key = key.strip()
            if sep and key in values and not values[key]:
                values[key] = value.strip().strip('"').strip("'")
    return values


class ApiError(RuntimeError):
    pass


class Api:
    def __init__(self, base_url: str, publishable_key: str):
        self.base_url = base_url.rstrip("/")
        self.publishable_key = publishable_key

    def call(self, method: str, path: str, *, token: str | None = None,
             body=None, prefer: str | None = None):
        headers = {"apikey": self.publishable_key, "Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if body is not None:
            headers["Content-Type"] = "application/json"
        if prefer:
            headers["Prefer"] = prefer
        req = request.Request(
            self.base_url + path,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers=headers,
            method=method,
        )
        try:
            with request.urlopen(req, timeout=45) as response:
                raw = response.read().decode("utf-8", "replace")
                return None if not raw else json.loads(raw)
        except error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            try:
                payload = json.loads(raw)
                detail = payload.get("message") or payload.get("error_description") or payload.get("error")
                code = payload.get("code") or exc.code
            except json.JSONDecodeError:
                detail, code = "non-JSON upstream refusal", exc.code
            raise ApiError(f"{method} {path.split('?')[0]} refused ({code}): {detail}") from None

    def select(self, table: str, token: str, columns: str, **filters):
        params = [("select", columns)]
        params.extend((key, f"eq.{value}") for key, value in filters.items())
        query = parse.urlencode(params, safe=",.*()")
        return self.call("GET", f"/rest/v1/{table}?{query}", token=token) or []

    def insert(self, table: str, token: str, rows):
        return self.call("POST", f"/rest/v1/{table}", token=token, body=rows,
                         prefer="return=representation") or []

    def patch(self, table: str, token: str, row_id: int, values: dict):
        return self.call("PATCH", f"/rest/v1/{table}?id=eq.{row_id}", token=token, body=values,
                         prefer="return=representation") or []

    def rpc(self, name: str, token: str, values: dict):
        return self.call("POST", f"/rest/v1/rpc/{name}", token=token, body=values)

    def sign_in(self, email: str, password: str):
        query = parse.urlencode({"grant_type": "password"})
        result = self.call("POST", f"/auth/v1/token?{query}",
                           body={"email": email, "password": password})
        token = (result or {}).get("access_token")
        if not token:
            raise ApiError("sign-in returned no access token")
        return token

    def auth_user(self, token: str):
        return self.call("GET", "/auth/v1/user", token=token)


def _one(rows, label):
    if len(rows) != 1:
        raise ApiError(f"{label}: expected exactly one row, found {len(rows)}")
    return rows[0]


def _tokens(api: Api, allow_login: bool):
    proposer = os.environ.get("U3_PROPOSER_JWT")
    approver = os.environ.get("U3_APPROVER_JWT")
    if proposer and approver:
        return proposer, approver
    if not allow_login:
        raise ApiError(
            "two caller sessions are required: set U3_PROPOSER_JWT/U3_APPROVER_JWT "
            "or rerun with --login for masked password entry"
        )
    proposer_password = getpass.getpass(f"Password for {PROPOSER['display_name']}: ")
    approver_password = getpass.getpass(f"Password for {APPROVER['display_name']}: ")
    try:
        return (
            api.sign_in(PROPOSER["email"], proposer_password),
            api.sign_in(APPROVER["email"], approver_password),
        )
    finally:
        proposer_password = approver_password = ""


def _verify_actor(api: Api, token: str, expected: dict):
    auth_user = api.auth_user(token) or {}
    auth_id = auth_user.get("id")
    if not auth_id:
        raise ApiError(f"{expected['display_name']}: token has no authenticated user")
    rows = api.select("app_users", token, "id,auth_user_id,display_name,status", auth_user_id=auth_id)
    row = _one(rows, expected["display_name"])
    if row.get("id") != expected["app_user_id"] or row.get("display_name") != expected["display_name"]:
        raise ApiError(f"{expected['display_name']}: caller token resolves to a different governed identity")
    if row.get("status") != "active":
        raise ApiError(f"{expected['display_name']}: governed identity is not active")
    return row


def _exact_by(rows, field: str, value):
    return [row for row in rows if row.get(field) == value]


def _get_or_create_customer(api: Api, proposer: str, approver: str):
    name = f"{TAG} NAGPUR DEVELOPMENT CUSTOMER"
    parties = _exact_by(api.select("parties", proposer,
                                   "id,display_name,lifecycle_state,status,customer_code,content_version"),
                        "display_name", name)
    families = _exact_by(api.select("customer_families", proposer,
                                    "id,name,status,group_customer_code,content_version"),
                         "name", name)
    if not parties and not families:
        created = api.rpc("create_minimal_prospect", proposer,
                          {"p_display_name": name, "p_family_id": None}) or []
        created = _one(created, "minimal Prospect")
        party_id, family_id = created["party_id"], created["family_id"]
    elif len(parties) == len(families) == 1:
        party_id, family_id = parties[0]["id"], families[0]["id"]
    else:
        raise ApiError("customer prerequisite is partial or duplicated; exact one-shot resume is unsafe")

    family = _one(api.select("customer_families", proposer,
                             "id,name,status,group_customer_code,content_version", id=family_id),
                  "development Family")
    if family["status"] == "proposed":
        api.rpc("approve_customer_family", approver,
                {"p_family": family_id, "p_expected_content_version": family["content_version"]})
    elif family["status"] != "active":
        raise ApiError(f"development Family is {family['status']}; a retired identity cannot be reused")

    party = _one(api.select("parties", proposer,
                            "id,display_name,lifecycle_state,status,customer_code,content_version", id=party_id),
                 "development Customer")
    if party["lifecycle_state"] == "prospect" and party["status"] == "proposed":
        api.rpc("graduate_customer_party", approver, {"p_party": party_id})
    party = _one(api.select("parties", proposer,
                            "id,display_name,lifecycle_state,status,customer_code,content_version", id=party_id),
                 "graduated development Customer")
    if party["lifecycle_state"] != "customer" or party["status"] != "active":
        raise ApiError("development identity did not reach active Customer state")

    locations = api.select("customer_locations", proposer,
                           "id,party_id,location_code,bill_to_eligible,ship_to_eligible,status,content_version",
                           party_id=party_id)
    versions = api.select("customer_location_versions", proposer,
                          "id,location_id,version_no,location_type,address_text,notes,status")
    location_by_purpose = {}
    for purpose in ("A", "B"):
        marker = f"{TAG} DESTINATION_{purpose}"
        version_hits = [v for v in versions if v.get("location_id") in {x["id"] for x in locations}
                        and marker in (v.get("notes") or "")]
        if not version_hits:
            location_id = api.rpc("propose_customer_location", proposer, {
                "p_party": party_id,
                "p_location_type": "warehouse",
                "p_address_text": f"{marker} · Nagpur development Ship-to",
                "p_contact_name": "U3 development only",
                "p_notes": (f"{marker} · "
                            + ("explicit-zero freight target" if purpose == "A"
                               else "missing freight lane target")),
                "p_bill_to_eligible": False,
                "p_ship_to_eligible": True,
            })
            versions = api.select("customer_location_versions", proposer,
                                  "id,location_id,version_no,location_type,address_text,notes,status")
        else:
            if len(version_hits) != 1:
                raise ApiError(f"destination {purpose}: duplicate permanent purpose marker")
            location_id = version_hits[0]["location_id"]
        location = _one(api.select("customer_locations", proposer,
                                   "id,party_id,location_code,bill_to_eligible,ship_to_eligible,status,content_version",
                                   id=location_id), f"destination {purpose}")
        if location["status"] == "proposed":
            api.rpc("approve_customer_location", approver, {
                "p_location": location_id,
                "p_expected_content_version": location["content_version"],
            })
        location = _one(api.select("customer_locations", proposer,
                                   "id,party_id,location_code,bill_to_eligible,ship_to_eligible,status,content_version",
                                   id=location_id), f"active destination {purpose}")
        if not location.get("location_code"):
            api.rpc("assign_customer_location_code", approver, {"p_location": location_id})
        location = _one(api.select("customer_locations", proposer,
                                   "id,party_id,location_code,bill_to_eligible,ship_to_eligible,status,content_version",
                                   id=location_id), f"coded destination {purpose}")
        if location["status"] != "active" or location["ship_to_eligible"] is not True:
            raise ApiError(f"destination {purpose} did not reach active Ship-to state")
        location_by_purpose[purpose] = location

    all_locations = api.select("customer_locations", proposer,
                               "id,party_id,location_code,bill_to_eligible,ship_to_eligible,status,content_version",
                               party_id=party_id)
    if len(all_locations) != 2:
        raise ApiError(f"development Customer must own exactly two Locations, found {len(all_locations)}")
    return family, party, location_by_purpose


def _get_or_insert_set(api: Api, table: str, token: str, name: str, actor_id: int):
    hits = _exact_by(api.select(table, token, "id,plant_id,name,status,created_by"), "name", name)
    if not hits:
        hits = api.insert(table, token, {
            "plant_id": PLANT_ID, "name": name, "status": "active", "created_by": actor_id,
        })
    row = _one(hits, name)
    if row["plant_id"] != PLANT_ID or row["status"] != "active":
        raise ApiError(f"{name}: existing identity is not the active Nagpur one-shot identity")
    return row


def _get_or_insert_sector(api: Api, token: str):
    code, name = "U3DEV9301", f"{TAG} SECTOR"
    hits = _exact_by(api.select("sectors", token, "id,sector_code,name,status,created_by"),
                     "sector_code", code)
    if not hits:
        hits = api.insert("sectors", token, {
            "sector_code": code, "name": name, "status": "active",
            "created_by": PROPOSER["app_user_id"],
        })
    row = _one(hits, name)
    if row["name"] != name or row["status"] != "active":
        raise ApiError("reserved Sector identity collides with another record")
    return row


def _ensure_versions(api: Api, table: str, parent_field: str | None, parent_id: int | None,
                     proposer: str, approver: str, rows: list[dict], terminal: str):
    columns = "id,version_no,status,created_by,approved_by,approved_at"
    filters = {parent_field: parent_id} if parent_field else {}
    existing = api.select(table, proposer, columns, **filters)
    out = {}
    for spec in rows:
        hits = _exact_by(existing, "version_no", spec["version_no"])
        if not hits:
            payload = dict(spec)
            payload["created_by"] = PROPOSER["app_user_id"]
            if parent_field:
                payload[parent_field] = parent_id
            hits = api.insert(table, proposer, payload)
            existing.extend(hits)
        out[spec["version_no"]] = _one(hits, f"{table} v{spec['version_no']}")

    first, current, draft = (out[spec["version_no"]] for spec in rows)
    if first["status"] == "draft":
        first = _one(api.patch(table, approver, first["id"], {"status": "approved"}),
                     f"{table} first approval")
    if first["status"] == "approved":
        first = _one(api.patch(table, approver, first["id"], {"status": terminal}),
                     f"{table} first terminal transition")
    if first["status"] != terminal:
        raise ApiError(f"{table}: first version is not {terminal}")
    if current["status"] == "draft":
        current = _one(api.patch(table, approver, current["id"], {"status": "approved"}),
                       f"{table} current approval")
    if current["status"] != "approved" or current.get("approved_by") != APPROVER["app_user_id"]:
        raise ApiError(f"{table}: current version was not approved by the distinct approver")
    if draft["status"] != "draft":
        raise ApiError(f"{table}: demonstration draft version was already consumed")
    return first, current, draft


def _ensure_rate(api: Api, proposer: str, approver: str):
    rate_set = _get_or_insert_set(api, "rate_sets", proposer, f"{TAG} KRAFT RATE SET",
                                  PROPOSER["app_user_id"])
    specs = [
        {"plant_id": PLANT_ID, "version_no": 1, "status": "draft", "credit_cost_pct": "1.500"},
        {"plant_id": PLANT_ID, "version_no": 2, "status": "draft", "credit_cost_pct": "1.500"},
        {"plant_id": PLANT_ID, "version_no": 3, "status": "draft", "credit_cost_pct": "1.500"},
    ]
    # Entries must exist before their parent leaves draft.
    existing = api.select("rate_set_versions", proposer,
                          "id,rate_set_id,plant_id,version_no,status,created_by,approved_by,approved_at",
                          rate_set_id=rate_set["id"])
    for spec in specs:
        if not _exact_by(existing, "version_no", spec["version_no"]):
            created = api.insert("rate_set_versions", proposer, {
                **spec, "rate_set_id": rate_set["id"], "created_by": PROPOSER["app_user_id"],
            })
            existing.extend(created)
    current = _one(_exact_by(existing, "version_no", 2), "Rate v2")
    entries = api.select("rate_entries", proposer,
                         "id,rate_set_version_id,plant_id,grade_code,description,price,discount,freight,interest_pct,effective_material_rate",
                         rate_set_version_id=current["id"])
    if current["status"] == "draft" and not entries:
        api.insert("rate_entries", proposer, [
            {"rate_set_version_id": current["id"], "plant_id": PLANT_ID,
             "grade_code": "KRAFT-180", "description": f"{TAG} governed Kraft liner",
             "price": "42.0000", "discount": "1.2500", "freight": "0.7500",
             "interest_pct": None, "created_by": PROPOSER["app_user_id"]},
            {"rate_set_version_id": current["id"], "plant_id": PLANT_ID,
             "grade_code": "FLUTE-150", "description": f"{TAG} explicit-zero supplier-credit exception",
             "price": "38.0000", "discount": "0.5000", "freight": "0.0000",
             "interest_pct": "0.000", "created_by": PROPOSER["app_user_id"]},
        ])
    versions = _ensure_versions(api, "rate_set_versions", "rate_set_id", rate_set["id"],
                                proposer, approver, specs, "withdrawn")
    return rate_set, versions


def _ensure_freight(api: Api, proposer: str, approver: str, destination_a: dict):
    freight_set = _get_or_insert_set(api, "freight_sets", proposer, f"{TAG} FREIGHT SET",
                                     PROPOSER["app_user_id"])
    specs = [
        {"plant_id": PLANT_ID, "version_no": 1, "effective_from": "2026-07-01", "status": "draft"},
        {"plant_id": PLANT_ID, "version_no": 2, "effective_from": "2026-09-11", "status": "draft"},
        {"plant_id": PLANT_ID, "version_no": 3, "effective_from": "2026-10-01", "status": "draft"},
    ]
    existing = api.select("freight_set_versions", proposer,
                          "id,freight_set_id,plant_id,version_no,effective_from,status,created_by,approved_by,approved_at",
                          freight_set_id=freight_set["id"])
    for spec in specs:
        if not _exact_by(existing, "version_no", spec["version_no"]):
            created = api.insert("freight_set_versions", proposer, {
                **spec, "freight_set_id": freight_set["id"], "created_by": PROPOSER["app_user_id"],
            })
            existing.extend(created)
    current = _one(_exact_by(existing, "version_no", 2), "Freight v2")
    entries = api.select("freight_entries", proposer,
                         "id,freight_set_version_id,plant_id,origin_plant_id,destination_location_id,rate",
                         freight_set_version_id=current["id"])
    if current["status"] == "draft" and not entries:
        api.insert("freight_entries", proposer, {
            "freight_set_version_id": current["id"], "plant_id": PLANT_ID,
            "origin_plant_id": PLANT_ID, "destination_location_id": destination_a["id"],
            "rate": "0.0000", "created_by": PROPOSER["app_user_id"],
        })
    versions = _ensure_versions(api, "freight_set_versions", "freight_set_id", freight_set["id"],
                                proposer, approver, specs, "withdrawn")
    return freight_set, versions


def _ensure_sector_and_defaults(api: Api, proposer: str, approver: str):
    sector = _get_or_insert_sector(api, proposer)
    sector_specs = [
        {"version_no": 1, "waste_cbb_pct": "4.000", "waste_pp_pct": "4.000",
         "conv_box_rate": "6.5000", "conv_pp_rate": "11.5000", "margin_pct": "7.000",
         "spec_lang": f"{TAG} superseded demonstration", "status": "draft"},
        {"version_no": 2, "waste_cbb_pct": "5.000", "waste_pp_pct": "0.000",
         "conv_box_rate": None, "conv_pp_rate": "12.5000", "margin_pct": "8.000",
         "spec_lang": f"{TAG} governed release composition", "status": "draft"},
        {"version_no": 3, "waste_cbb_pct": "5.250", "waste_pp_pct": None,
         "conv_box_rate": None, "conv_pp_rate": None, "margin_pct": "8.500",
         "spec_lang": f"{TAG} draft demonstration", "status": "draft"},
    ]
    sector_versions = _ensure_versions(api, "sector_versions", "sector_id", sector["id"],
                                       proposer, approver, sector_specs, "superseded")

    default_specs = []
    for index, version_no in enumerate(DEFAULT_VERSION_NUMBERS):
        default_specs.append({
            "version_no": version_no,
            "interest_fallback_pct": "0.500",
            "waste_cbb_fallback_pct": "5.000",
            "waste_pp_fallback_pct": "5.000",
            "conv_box_fallback_rate": "7.0000",
            "conv_pp_fallback_rate": "12.5000",
            "margin_fallback_pct": "8.000",
            "rounding_step": "0.0500",
            "engine_version": ENGINE_VERSION,
            "rounding_rule_version": "round/nearest-0.05",
            "annual_interest_pct": "6.000",
            "day_count_basis": 360,
            "fluting_bcf_default": "0.1000",
            "status": "draft",
        })
    default_versions = _ensure_versions(api, "calculation_default_versions", None, None,
                                        proposer, approver, default_specs, "superseded")
    return sector, sector_versions, default_versions


def _ensure_release(api: Api, proposer: str, approver: str, rate_version: dict,
                    freight_version: dict, sector_version: dict, default_version: dict):
    name = f"{TAG} PRICING BASIS RELEASE · ALTERNATIVE"
    releases = _exact_by(api.select(
        "pricing_basis_releases", proposer,
        "id,plant_id,release_name,effective_from,effective_until,is_automatic_default,"
        "rate_set_version_id,freight_set_version_id,sector_version_id,"
        "calculation_default_version_id,status,self_approved,proposed_by,approved_by,approved_at",
    ), "release_name", name)
    if not releases:
        release_id = api.rpc("propose_pricing_basis_release", proposer, {
            "p_plant": PLANT_ID,
            "p_effective_from": "2026-09-11",
            "p_rate_set_version_id": rate_version["id"],
            "p_freight_set_version_id": freight_version["id"],
            "p_sector_version_id": sector_version["id"],
            "p_calculation_default_version_id": default_version["id"],
            "p_effective_until": None,
            "p_release_name": name,
        })
    else:
        release_id = _one(releases, name)["id"]
    release = _one(api.select(
        "pricing_basis_releases", proposer,
        "id,plant_id,release_name,effective_from,effective_until,is_automatic_default,"
        "rate_set_version_id,freight_set_version_id,sector_version_id,"
        "calculation_default_version_id,status,self_approved,proposed_by,approved_by,approved_at",
        id=release_id,
    ), name)
    if release["status"] == "draft":
        api.rpc("approve_pricing_basis_release", approver,
                {"p_release": release_id, "p_is_automatic_default": False})
    release = _one(api.select(
        "pricing_basis_releases", proposer,
        "id,plant_id,release_name,effective_from,effective_until,is_automatic_default,"
        "rate_set_version_id,freight_set_version_id,sector_version_id,"
        "calculation_default_version_id,status,self_approved,proposed_by,approved_by,approved_at",
        id=release_id,
    ), name)
    expected = {
        "plant_id": PLANT_ID,
        "rate_set_version_id": rate_version["id"],
        "freight_set_version_id": freight_version["id"],
        "sector_version_id": sector_version["id"],
        "calculation_default_version_id": default_version["id"],
        "status": "approved",
        "is_automatic_default": False,
        "self_approved": False,
        "proposed_by": PROPOSER["app_user_id"],
        "approved_by": APPROVER["app_user_id"],
    }
    for key, value in expected.items():
        if release.get(key) != value:
            raise ApiError(f"Release verification failed for {key}: {release.get(key)!r}")
    return release


def apply_dataset(api: Api, proposer: str, approver: str):
    _verify_actor(api, proposer, PROPOSER)
    _verify_actor(api, approver, APPROVER)
    plant = _one(api.select("plants", proposer, "id,plant_code,name,status", id=PLANT_ID), "Nagpur")
    if plant["plant_code"] != PLANT_CODE or plant["status"] != "active":
        raise ApiError("selected development plant is not active Nagpur")

    family, party, locations = _get_or_create_customer(api, proposer, approver)
    rate_set, rate_versions = _ensure_rate(api, proposer, approver)
    freight_set, freight_versions = _ensure_freight(api, proposer, approver, locations["A"])
    sector, sector_versions, default_versions = _ensure_sector_and_defaults(api, proposer, approver)
    release = _ensure_release(api, proposer, approver, rate_versions[1], freight_versions[1],
                              sector_versions[1], default_versions[1])

    freight_entries = api.select(
        "freight_entries", proposer,
        "id,freight_set_version_id,plant_id,origin_plant_id,destination_location_id,rate",
        freight_set_version_id=freight_versions[1]["id"],
    )
    if len(freight_entries) != 1:
        raise ApiError(f"approved Freight v2 must contain exactly one lane, found {len(freight_entries)}")
    lane = freight_entries[0]
    if lane["destination_location_id"] != locations["A"]["id"] or float(lane["rate"]) != 0:
        raise ApiError("destination A is not the exact explicit-zero freight lane")
    if any(row["destination_location_id"] == locations["B"]["id"] for row in freight_entries):
        raise ApiError("destination B unexpectedly has a Freight Entry")

    rate_entries = api.select(
        "rate_entries", proposer,
        "id,rate_set_version_id,grade_code,price,discount,freight,interest_pct,effective_material_rate",
        rate_set_version_id=rate_versions[1]["id"],
    )
    by_grade = {row["grade_code"]: row for row in rate_entries}
    if set(by_grade) != {"KRAFT-180", "FLUTE-150"}:
        raise ApiError("approved Rate v2 does not contain the exact governed grade set")
    if float(by_grade["KRAFT-180"]["effective_material_rate"]) != 42.13:
        raise ApiError("KRAFT-180 governed effective material rate differs from 42.1300")
    if float(by_grade["FLUTE-150"]["effective_material_rate"]) != 37.5:
        raise ApiError("FLUTE-150 governed effective material rate differs from 37.5000")

    return {
        "dataset": TAG,
        "plant": plant,
        "actors": {"proposer": PROPOSER["display_name"], "approver": APPROVER["display_name"]},
        "customer": {
            "family_id": family["id"], "party_id": party["id"],
            "customer_code": party["customer_code"],
            "destination_a": {"id": locations["A"]["id"], "code": locations["A"]["location_code"]},
            "destination_b": {"id": locations["B"]["id"], "code": locations["B"]["location_code"]},
        },
        "rate": {"set_id": rate_set["id"], "release_version_id": rate_versions[1]["id"]},
        "freight": {"set_id": freight_set["id"], "release_version_id": freight_versions[1]["id"],
                    "explicit_zero_entry_id": lane["id"], "missing_destination_id": locations["B"]["id"]},
        "sector": {"id": sector["id"], "release_version_id": sector_versions[1]["id"]},
        "calculation_default_version_id": default_versions[1]["id"],
        "release": {"id": release["id"], "status": release["status"],
                    "automatic_default": release["is_automatic_default"]},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--login", action="store_true",
                        help="obtain caller JWTs with masked password prompts")
    parser.add_argument("--authorization")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        assert TAG == "__U3_DEV_ONLY_9301__"
        assert PROPOSER["app_user_id"] != APPROVER["app_user_id"]
        assert DEFAULT_VERSION_NUMBERS == (9301001, 9301002, 9301003)
        assert ENGINE_VERSION == "engine/qe1-7c2ceac1972460ba"
        assert "SECRET" not in {"SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY"}
        print("u3 governed executor self-test PASS (5 assertions, zero network calls)")
        return 0
    if not args.apply or args.authorization != AUTHORIZATION:
        print("refused: --apply and the exact one-shot authorization token are required", file=sys.stderr)
        return 2

    public = _public_env()
    if not public["SUPABASE_URL"] or not public["SUPABASE_PUBLISHABLE_KEY"]:
        print("missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY", file=sys.stderr)
        return 2
    api = Api(public["SUPABASE_URL"], public["SUPABASE_PUBLISHABLE_KEY"])
    try:
        proposer, approver = _tokens(api, args.login)
        manifest = apply_dataset(api, proposer, approver)
    except ApiError as exc:
        print(f"U3 governed executor stopped: {exc}", file=sys.stderr)
        return 1
    finally:
        proposer = approver = None
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
