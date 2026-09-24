"""U4 durable Batch Pricing Basis read/governed-write route gate."""
import json
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


ROWS = {
    "batches": [{
        "id": 71, "batch_reference": "NAG/BAT/2026-27/00071", "plant_id": 7,
        "family_id": 21, "owner_user_id": 4, "sector_id": 31,
        "status": "working", "content_version": 7, "pricing_date": "2026-09-11",
        "pricing_basis_release_id": 11, "pricing_basis_is_deliberate": False,
        "price_validity_from": "2026-09-11", "price_validity_to": "2026-10-10",
        "created_at": "2026-09-11T08:00:00Z", "created_by": 4,
    }],
    "plants": [
        {"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
        {"id": 8, "plant_code": "PUN", "name": "Pune", "status": "active"},
    ],
    "customer_families": [{"id": 21, "group_customer_code": "FAM-021",
                           "name": "Fixture Family", "status": "active", "content_version": 3}],
    "customer_family_sectors": [
        {"family_id": 21, "sector_id": 31, "created_at": "2026-08-01T08:00:00Z"},
        {"family_id": 21, "sector_id": 32, "created_at": "2026-08-02T08:00:00Z"},
    ],
    "app_users": [
        {"id": 4, "display_name": "Fixture Maker", "status": "active"},
        {"id": 5, "display_name": "Fixture Collaborator", "status": "active"},
    ],
    "sectors": [
        {"id": 31, "sector_code": "PIZZA", "name": "Pizza", "status": "active"},
        {"id": 32, "sector_code": "FMCG", "name": "FMCG", "status": "active"},
    ],
    "batch_profile_versions": [{
        "id": 41, "batch_id": 71, "version_no": 3, "waste_cbb_pct": None,
        "waste_pp_pct": 0, "conv_box_rate": 7, "conv_pp_rate": 12.5,
        "margin_box_pct": None, "margin_pp_pct": 8, "is_current": True,
        "created_at": "2026-09-11T08:10:00Z", "created_by": 4,
    }],
    "batch_collaborators": [{"id": 51, "batch_id": 71, "app_user_id": 5,
                              "status": "active", "created_at": "2026-09-11T08:15:00Z"}],
    "batch_edit_locks": [{"id": 61, "batch_id": 71, "holder_user_id": 4,
                           "acquired_at": "2026-09-11T08:20:00Z",
                           "heartbeat_at": "2026-09-11T08:25:00Z", "released_at": None}],
    "pricing_groups": [{
        "id": 81, "batch_id": 71, "label": "Standard", "freight_mode": "master",
        "freight_basis_delivery_group_id": 91, "freight_manual_value": None,
        "payment_terms_days": 30, "payment_terms_text": None,
        "interest_override_pct": None, "interest_override_derived_pct": None,
        "interest_override_reason": None, "interest_override_by": None,
        "interest_override_at": None,
        "status": "active", "content_version": 2,
        "legacy_freight_value": None, "legacy_freight_source": None,
    }],
    "delivery_groups": [{
        "id": 91, "pricing_group_id": 81, "batch_id": 71, "label": "Nagpur delivery",
        "bill_to_location_id": 101, "ship_to_location_id": 102,
        "destination_text": None, "billing_text": None, "route_notes": None, "status": "active",
    }],
    "customer_locations": [
        {"id": 101, "party_id": 201, "location_code": "BILL-101",
         "bill_to_eligible": True, "ship_to_eligible": False, "status": "active", "content_version": 1},
        {"id": 102, "party_id": 201, "location_code": "SHIP-102",
         "bill_to_eligible": False, "ship_to_eligible": True, "status": "active", "content_version": 2},
        {"id": 103, "party_id": 201, "location_code": "SHIP-103",
         "bill_to_eligible": False, "ship_to_eligible": True, "status": "active", "content_version": 1},
    ],
    "parties": [{"id": 201, "customer_code": "CUST-201", "display_name": "Fixture Customer",
                 "lifecycle_state": "customer", "status": "active"}],
    "party_family_memberships": [{"party_id": 201, "family_id": 21, "is_current": True}],
    "skus": [
        {"id": 301, "plant_id": 7, "party_id": 201, "plant_item_code": "NAG-SKU-301",
         "status": "active", "replacement_sku_id": None, "content_version": 2},
        {"id": 302, "plant_id": 8, "party_id": 201, "plant_item_code": "PUN-SKU-302",
         "status": "active", "replacement_sku_id": None, "content_version": 1},
        {"id": 303, "plant_id": 7, "party_id": 201, "plant_item_code": None,
         "status": "withdrawn", "replacement_sku_id": None, "content_version": 3},
    ],
    "sku_versions": [
        {"id": 311, "sku_id": 301, "plant_id": 7, "version_no": 2,
         "construction_version_id": 321, "is_price_driving": False,
         "length_mm": 400, "width_mm": 300, "height_mm": 250, "box_type": "RSC",
         "ups": 1, "spec_bs": 8, "spec_bct": 120, "spec_ect": 32,
         "approved_at": "2026-09-01T08:00:00Z"},
        {"id": 312, "sku_id": 301, "plant_id": 7, "version_no": 3,
         "construction_version_id": 322, "is_price_driving": True,
         "length_mm": 410, "width_mm": 310, "height_mm": 260, "box_type": "RSC",
         "ups": 1, "spec_bs": 9, "spec_bct": 130, "spec_ect": 34,
         "approved_at": None},
        # Amendment 04 D-01: unapproved, on an ADOPTED Construction - quotable, labelled.
        {"id": 313, "sku_id": 301, "plant_id": 7, "version_no": 4,
         "construction_version_id": 321, "is_price_driving": False,
         "length_mm": 400, "width_mm": 300, "height_mm": 250, "box_type": "RSC",
         "ups": 1, "spec_bs": 8, "spec_bct": 120, "spec_ect": 32,
         "approved_at": None},
        {"id": 314, "sku_id": 303, "plant_id": 7, "version_no": 1,
         "construction_version_id": 321, "is_price_driving": True,
         "length_mm": 300, "width_mm": 200, "height_mm": 100, "box_type": "RSC",
         "ups": 1, "spec_bs": 8, "spec_bct": 120, "spec_ect": 32,
         "approved_at": None},
    ],
    "constructions": [
        {"id": 331, "construction_code": "5P-180-22", "name": "Fixture 5 ply",
         "status": "published", "surviving_construction_id": None},
        {"id": 332, "construction_code": "3P-DRAFT", "name": "Draft construction",
         "status": "proposed", "surviving_construction_id": None},
    ],
    "construction_versions": [
        {"id": 321, "construction_id": 331, "version_no": 4, "ply": 5,
         "flute_f1": "B", "flute_f2": "C", "board_gsm": 720,
         "effective_from": "2026-09-01", "approved_at": "2026-08-30T08:00:00Z"},
        {"id": 322, "construction_id": 332, "version_no": 1, "ply": 3,
         "flute_f1": "B", "flute_f2": None, "board_gsm": 420,
         "effective_from": None, "approved_at": None},
    ],
    "plant_construction_adoptions": [
        {"plant_id": 7, "construction_version_id": 321, "status": "adopted"},
    ],
    "sku_external_references": [
        {"id": 341, "sku_id": 301, "plant_id": 7, "reference_kind": "customer_item_code",
         "reference_value": "CUST-BOX-301", "status": "active"},
    ],
    "batch_rows": [{
        "id": 351, "lineage_id": 9301, "batch_id": 71, "plant_id": 7,
        "pricing_group_id": 81, "sku_id": 301, "sku_version_id": 311,
        "proposed_construction_version_id": None, "material_code": "NAG-SKU-301",
        "row_type": "box", "waste_override_pct": None, "margin_override_pct": None,
        "conv_override_rate": None, "freight_override": None, "sales_moq": 1000,
        "volume": 5000, "status": "active", "content_version": 2,
        "addon_printing": None, "addon_stitching": None, "addon_coating": None,
        "addon_handling": None, "addon_moq_charge": None, "addon_packing": None,
        "addon_other": None, "addon_unloading": None, "fluting_bcf": None,
    }],
    "batch_calculations": [],
    "batch_sets": [],
    "batch_set_memberships": [],
    "pricing_basis_releases": [
        {"id": 11, "plant_id": 7, "release_name": "Nagpur Default", "status": "approved",
         "effective_from": "2026-09-01", "effective_until": None,
         "is_automatic_default": True, "created_at": "2026-08-25T09:00:00Z",
         "approved_at": "2026-08-28T09:00:00Z", "withdrawn_at": None,
         "calculation_default_version_id": 501},
        {"id": 12, "plant_id": 7, "release_name": "Nagpur Alternative", "status": "approved",
         "effective_from": "2026-10-01", "effective_until": "2026-12-31",
         "is_automatic_default": False, "created_at": "2026-09-01T09:00:00Z",
         "approved_at": "2026-09-03T09:00:00Z", "withdrawn_at": None,
         "calculation_default_version_id": 501},
    ],
    "calculation_default_versions": [{
        "id": 501, "annual_interest_pct": 6.0, "day_count_basis": 360,
    }],
}
CALLS, RPC_CALLS, TABLE_WRITES, DENIED_TABLES, DENIED_ACTIONS = [], [], [], set(), set()
CALCULATE_INPUTS_ERROR = None
# S3 readiness: per-row gatherer refusals, {row_id: (sqlstate, message)}.
CALCULATE_INPUTS_ROW_ERRORS = {}
CALLER = None


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table, self.columns, self.filters, self.in_filters, self.maximum = token, table, "*", [], [], None
        self.action, self.payload = "select", None

    def select(self, columns):
        self.columns = columns
        return self

    def eq(self, column, value):
        self.filters.append((column, value))
        return self

    def in_(self, column, values):
        self.in_filters.append((column, set(values)))
        return self

    def lt(self, column, value):
        self.filters.append((f"{column}__lt", value))
        return self

    def order(self, column, desc=False):
        self.order_by = (column, desc)
        return self

    def limit(self, maximum):
        self.maximum = maximum
        return self

    def insert(self, payload):
        self.action, self.payload = "insert", dict(payload)
        return self

    def update(self, payload):
        self.action, self.payload = "update", dict(payload)
        return self

    def execute(self):
        if self.table in DENIED_TABLES or (self.table, self.action) in DENIED_ACTIONS:
            raise server.APIError({"code": "42501", "message": "denied",
                                   "details": None, "hint": None})
        CALLS.append((self.token, self.table, tuple(self.filters), self.maximum))
        source = ROWS.setdefault(self.table, [])
        if self.action == "insert":
            row = {**self.payload, "id": max((item.get("id", 0) for item in source), default=0) + 1}
            if self.table == "pricing_groups":
                row.update({
                    "freight_mode": "master", "freight_basis_delivery_group_id": None,
                    "freight_manual_value": None, "payment_terms_days": None,
                    "payment_terms_text": None, "interest_override_pct": None,
                    "interest_override_derived_pct": None, "interest_override_reason": None,
                    "interest_override_by": None, "interest_override_at": None,
                    "content_version": 1, "legacy_freight_value": None,
                    "legacy_freight_source": None, **self.payload,
                })
            if self.table == "delivery_groups":
                row.setdefault("status", "active")
            if self.table == "batch_rows":
                row.setdefault("lineage_id", 9300 + row["id"])
                row.setdefault("content_version", 1)
            if self.table == "batch_sets":
                row.update({"status": "dissolved", "active_component_count": 0})
            source.append(row)
            if self.table == "batch_set_memberships":
                target = next(item for item in ROWS["batch_sets"] if item["id"] == row["set_id"])
                active = [item for item in source if item["set_id"] == row["set_id"] and item["status"] == "active"]
                target.update({"active_component_count": len(active), "status": "active" if active else "dissolved"})
            TABLE_WRITES.append((self.token, self.table, self.action, dict(self.payload)))
            return type("Response", (), {"data": [dict(row)]})()

        matched = list(source)
        for column, value in self.filters:
            if column.endswith("__lt"):
                matched = [row for row in matched if row.get(column[:-4], 0) < value]
            else:
                matched = [row for row in matched if str(row.get(column)) == str(value)]
        for column, values in self.in_filters:
            matched = [row for row in matched if row.get(column) in values]
        if hasattr(self, "order_by"):
            column, desc = self.order_by
            matched.sort(key=lambda row: row.get(column) or 0, reverse=desc)
        if self.action == "update":
            for row in matched:
                row.update(self.payload)
                if self.table in ("pricing_groups", "batch_rows"):
                    row["content_version"] += 1
            if self.table == "batch_set_memberships" and matched:
                target = next(item for item in ROWS["batch_sets"] if item["id"] == matched[0]["set_id"])
                active = [item for item in source if item["set_id"] == target["id"] and item["status"] == "active"]
                target.update({"active_component_count": len(active), "status": "active" if active else "dissolved"})
            TABLE_WRITES.append((self.token, self.table, self.action, dict(self.payload)))
            return type("Response", (), {"data": [dict(row) for row in matched]})()

        rows = [dict(row) for row in matched]
        if self.maximum is not None:
            rows = rows[:self.maximum]
        wanted = [part.strip() for part in self.columns.split(",")]
        rows = [{key: row.get(key) for key in wanted} for row in rows]
        return type("Response", (), {"data": rows})()


class FakeRpc:
    def __init__(self, token, name, params):
        self.token, self.name, self.params = token, name, params

    def execute(self):
        global CALCULATE_INPUTS_ERROR
        RPC_CALLS.append((self.token, self.name, dict(self.params)))
        if self.name == "calculate_inputs":
            if CALCULATE_INPUTS_ERROR:
                raise server.APIError({"code": CALCULATE_INPUTS_ERROR, "message": "not ready",
                                       "details": None, "hint": None})
            row_error = CALCULATE_INPUTS_ROW_ERRORS.get(self.params["p_batch_row_id"])
            if row_error:
                raise server.APIError({"code": row_error[0], "message": row_error[1],
                                       "details": None, "hint": None})
            return type("Response", (), {"data": {
                "effective_inputs": {"resolved": {
                    "waste": {"value": 0, "source": "row"},
                    "conv": {"value": 7, "source": "batch_profile"},
                    "margin": {"value": 8, "source": "sector_version"},
                    "freight": {"value": 2, "source": "freight_master"},
                    "interest": {"value": 0.5, "source": "derived_annual"},
                }},
                "binding": {
                    "batch_id": 71, "batch_row_id": self.params["p_batch_row_id"],
                    "content_version": 2, "engine_version": "engine/qe1-7c2ceac1972460ba",
                    "calculation_fingerprint": "calc-fp-current",
                    "presentation_fingerprint": "present-fp-current",
                },
            }})()
        if self.name == "set_batch_pricing_basis":
            batch = ROWS["batches"][0]
            batch["pricing_date"] = self.params["p_pricing_date"]
            batch["pricing_basis_release_id"] = 11 if self.params["p_release"] is None else self.params["p_release"]
            batch["pricing_basis_is_deliberate"] = self.params["p_release"] is not None
            batch["content_version"] += 1
            return type("Response", (), {"data": None})()
        if self.name == "revise_batch_profile":
            batch = next(row for row in ROWS["batches"] if row["id"] == self.params["p_batch"])
            if batch["content_version"] != self.params["p_expected_content_version"]:
                raise server.APIError({"code": "40001", "message": "stale", "details": None, "hint": None})
            current = next(row for row in ROWS["batch_profile_versions"]
                           if row["batch_id"] == batch["id"] and row["is_current"])
            current["is_current"] = False
            profile = {"id": max(row["id"] for row in ROWS["batch_profile_versions"]) + 1,
                       "batch_id": batch["id"], "version_no": current["version_no"] + 1,
                       "is_current": True, "created_at": "2026-09-12T10:00:00Z", "created_by": CALLER["id"]}
            for field in ("waste_cbb_pct", "waste_pp_pct", "conv_box_rate", "conv_pp_rate",
                          "margin_box_pct", "margin_pp_pct"):
                profile[field] = self.params[f"p_{field}"]
            ROWS["batch_profile_versions"].append(profile)
            batch["content_version"] += 1
            return type("Response", (), {"data": profile["id"]})()
        if self.name == "create_minimal_prospect":
            family_id = self.params.get("p_family_id")
            if family_id is None:
                family_id = max(row["id"] for row in ROWS["customer_families"]) + 1
                ROWS["customer_families"].append({"id": family_id,
                    "group_customer_code": None, "name": self.params["p_display_name"],
                    "status": "proposed"})
                ROWS["customer_family_sectors"].append({"family_id": family_id,
                    "sector_id": self.params["p_sector"], "created_at": "2026-09-23T09:00:00Z"})
            party_id = max(row["id"] for row in ROWS["parties"]) + 1
            ROWS["parties"].append({"id": party_id, "customer_code": None,
                "display_name": self.params["p_display_name"],
                "lifecycle_state": "prospect", "status": "proposed"})
            ROWS["party_family_memberships"].append({"party_id": party_id,
                "family_id": family_id, "is_current": True})
            return type("Response", (), {"data": [{"party_id": party_id, "family_id": family_id}]})()
        if self.name == "create_batch_handoff":
            party = next((row for row in ROWS["parties"] if row["id"] == self.params["p_party"]
                          and ((row["lifecycle_state"] == "customer" and row["status"] == "active")
                               or (row["lifecycle_state"] == "prospect"
                                   and row["status"] in ("proposed", "active")))), None)
            member = next((row for row in ROWS["party_family_memberships"]
                           if row["party_id"] == self.params["p_party"]
                           and row["family_id"] == self.params["p_family"]
                           and row["is_current"]), None)
            family = next((row for row in ROWS["customer_families"]
                           if row["id"] == self.params["p_family"]
                           and row["status"] in ("proposed", "active")), None)
            location = next((row for row in ROWS["customer_locations"]
                             if row["id"] == self.params["p_ship_to"]
                             and row["party_id"] == self.params["p_party"]
                             and row["status"] == "active" and row["ship_to_eligible"]), None)
            billing = next((row for row in ROWS["customer_locations"]
                            if row["id"] == self.params["p_bill_to"]
                            and row["party_id"] == self.params["p_party"]
                            and row["status"] == "active" and row["bill_to_eligible"]), None)
            if not party or not member or not family or (self.params["p_ship_to"] and not location) or (self.params["p_bill_to"] and not billing):
                raise server.APIError({"code": "22023", "message": "invalid customer context",
                                       "details": None, "hint": None})
            batch_id = max(row["id"] for row in ROWS["batches"]) + 1
            ROWS["batches"].append({
                "id": batch_id, "batch_reference": f"NAG/BAT/2026-27/{batch_id:05d}",
                "plant_id": self.params["p_plant"], "family_id": self.params["p_family"],
                "customer_party_id": self.params["p_party"],
                "owner_user_id": CALLER["id"], "sector_id": self.params["p_sector"],
                "status": "working", "content_version": 1, "pricing_date": "2026-09-12",
                "pricing_basis_release_id": 11, "pricing_basis_is_deliberate": False,
                "price_validity_from": None, "price_validity_to": None,
                "created_at": "2026-09-12T09:00:00Z", "created_by": CALLER["id"],
            })
            ROWS["batch_edit_locks"].append({
                "id": 62, "batch_id": batch_id, "holder_user_id": CALLER["id"],
                "acquired_at": "2026-09-12T09:00:00Z", "heartbeat_at": "2026-09-12T09:00:00Z",
                "released_at": None,
            })
            ROWS["pricing_groups"].append({
                "id": 82, "batch_id": batch_id, "label": "Default", "freight_mode": "master",
                "freight_basis_delivery_group_id": None, "freight_manual_value": None,
                "payment_terms_days": self.params["p_payment_terms_days"], "payment_terms_text": None,
                "interest_override_pct": None, "interest_override_derived_pct": None,
                "interest_override_reason": None, "interest_override_by": None,
                "interest_override_at": None,
                "status": "active", "content_version": 1,
                "legacy_freight_value": None, "legacy_freight_source": None,
            })
            ROWS["delivery_groups"].append({
                "id": 93, "pricing_group_id": 82, "batch_id": batch_id, "label": "Default",
                "bill_to_location_id": self.params["p_bill_to"], "ship_to_location_id": self.params["p_ship_to"],
                "destination_text": self.params["p_destination_text"],
                "billing_text": self.params["p_billing_text"],
                "route_notes": None, "status": "active",
            })
            ROWS["batch_profile_versions"].append({
                "id": 42, "batch_id": batch_id, "version_no": 1,
                "waste_cbb_pct": None, "waste_pp_pct": None, "conv_box_rate": None,
                "conv_pp_rate": None, "margin_box_pct": None, "margin_pp_pct": None,
                "is_current": True, "created_at": "2026-09-12T09:00:00Z",
                "created_by": CALLER["id"],
            })
            return type("Response", (), {"data": batch_id})()
        lock = next((row for row in ROWS["batch_edit_locks"]
                     if row["batch_id"] == self.params["p_batch"]), None)
        if self.name == "release_batch_lock":
            if lock and lock["holder_user_id"] == CALLER["id"]:
                lock["released_at"] = "2026-09-12T09:05:00Z"
            return type("Response", (), {"data": None})()
        if self.name == "acquire_batch_lock":
            if lock:
                lock.update({"holder_user_id": CALLER["id"], "released_at": None,
                             "heartbeat_at": "2026-09-12T09:06:00Z"})
                return type("Response", (), {"data": lock["id"]})()
        if self.name == "reclaim_batch_lock":
            if lock and lock["holder_user_id"] == self.params["p_expected_holder"]:
                lock.update({"holder_user_id": CALLER["id"], "released_at": None,
                             "acquired_at": "2026-09-12T09:08:00Z",
                             "heartbeat_at": "2026-09-12T09:08:00Z"})
                return type("Response", (), {"data": lock["id"]})()
            raise server.APIError({"code": "55P03", "message": "lock holder changed",
                                   "details": None, "hint": None})
        if self.name == "heartbeat_batch_lock":
            if lock and lock["holder_user_id"] == CALLER["id"] and lock["released_at"] is None:
                lock["heartbeat_at"] = "2026-09-12T09:07:00Z"
                return type("Response", (), {"data": None})()
        raise AssertionError("unexpected RPC")


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-u4", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)

    def rpc(self, name, params):
        return FakeRpc(self.token, name, params)


def fake_client(token):
    return FakeClient(token)


cc.get_supabase_for_caller = fake_client
cc.new_caller_client = fake_client

import server  # noqa: E402
import auth as auth_mod  # noqa: E402

server.get_supabase_for_caller = fake_client
server.new_caller_client = fake_client
auth_mod.get_supabase_for_caller = fake_client
auth_mod.resolve_caller = lambda _token, known_auth_uid=None: CALLER
server.privileged_client = lambda _operation: (_ for _ in ()).throw(
    AssertionError("U4 Batch Pricing Basis must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-u4"}

with app.test_client() as client:
    response = client.get("/batches/pricing-basis?reference=NAG%2FBAT%2F2026-27%2F00071")
check(response.status_code == 401, "U4-PB-1 anonymous Batch read is refused")

with app.test_client() as client:
    response = client.post("/batches", json={"family_id": 21, "plant_id": 7, "sector_id": 31})
check(response.status_code == 401, "U4-NEW-1 anonymous governed Batch creation is refused")

CALLER = {"id": 4, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": []}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/batches/create-options", headers=AUTH)
check(response.status_code == 403 and not CALLS,
      "U4-NEW-2 creation options refuse callers who cannot read Customer identities")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31, "customer_party_id": 201,
        "ship_to_location_id": 102, "bill_to_location_id": 101,
        "payment_terms_days": 45,
    })
check(response.status_code == 403 and not RPC_CALLS,
      "HANDOFF-AUTH-1 make_quote alone cannot hand guessed Party and Location IDs to the definer")

CALLER["group_capabilities"] = ["read_party_master"]
CALLS.clear()
with app.test_client() as client:
    response = client.get("/batches/create-options", headers=AUTH)
options = response.get_json()
check(response.status_code == 200
      and [(plant["id"], plant["plant_code"]) for plant in options["plants"]] == [(7, "NAG")]
      and options["families"][0]["members"][0]["customer_code"] == "CUST-201"
      and [location["id"] for location in options["families"][0]["members"][0]["delivery_locations"]] == [102, 103]
      and [location["id"] for location in options["families"][0]["members"][0]["billing_locations"]] == [101]
      and options["families"][0]["sector_ids"] == [31, 32]
      and {sector["id"] for sector in options["sectors"]} == {31, 32},
      "U4-NEW-3 creation options expose exact caller-visible Family/member, Maker Plant and Sector identities")
check(CALLS and all(call[0] == "tok-u4" for call in CALLS),
      "U4-NEW-4 every creation-options read carries the caller token")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={"family_id": "", "plant_id": 7})
check(response.status_code == 400 and not RPC_CALLS,
      "U4-NEW-5 invalid Batch identity input is refused before the governed RPC")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={"family_id": 21, "plant_id": 7})
check(response.status_code == 400 and not RPC_CALLS,
      "U4-NEW-5a a Batch without exactly one selected Family Sector is refused before the governed RPC")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 201, "ship_to_location_id": 102,
        "bill_to_location_id": 101, "payment_terms_days": 45,
    })
created = response.get_json()["batch"]
created_batch_id = created["id"]
check(response.status_code == 201
      and RPC_CALLS[-1] == ("tok-u4", "create_batch_handoff", {
          "p_family": 21, "p_plant": 7, "p_sector": 31, "p_party": 201,
          "p_ship_to": 102, "p_bill_to": 101,
          "p_destination_text": None, "p_billing_text": None,
          "p_payment_terms_days": 45,
      }), "U4-NEW-6 new Batch creation uses the exact governed RPC with the caller token")
check(created["batch_reference"].startswith("NAG/BAT/2026-27/")
      and created["pricing_date"] == "2026-09-12"
      and created["pricing_basis_release_id"] == 11
      and created["pricing_groups"][0]["label"] == "Default"
      and created["pricing_groups"][0]["delivery_groups"][0]["label"] == "Default"
      and created["customer_party"]["display_name"] == "Fixture Customer"
      and created["pricing_groups"][0]["payment_terms_days"] == 45
      and created["pricing_groups"][0]["delivery_groups"][0]["ship_to_location_id"] == 102
      and created["pricing_groups"][0]["delivery_groups"][0]["bill_to_location_id"] == 101
      and created["current_profile"]["version_no"] == 1
      and created["caller_holds_lock"] is True,
      "U4-NEW-7 creation reads back the permanent reference, Pricing Basis, default groups, profile and initial lock")
check(CALLS and all(call[0] == "tok-u4" for call in CALLS),
      "U4-NEW-8 the created workspace read-back remains caller-scoped")

with app.test_client() as client:
    response = client.get(f"/batches/{created_batch_id}/workspace", headers=AUTH)
reopened = response.get_json()["batch"]
check(response.status_code == 200 and reopened["customer_party_id"] == 201
      and reopened["customer_party"]["display_name"] == "Fixture Customer"
      and reopened["pricing_groups"][0]["payment_terms_days"] == 45
      and reopened["pricing_groups"][0]["delivery_groups"][0]["ship_to_location_id"] == 102,
      "HANDOFF-1 single-member Customer, delivery and terms survive workspace reopen")

# The main Maker journey must prove the established-SKU lane independently of
# the proposed Prospect/SKU lane below.  This is the authenticated in-memory
# HTTP harness: no trial/main project row is written.
with app.test_client() as client:
    response = client.get(f"/batches/{created_batch_id}/row-options", headers=AUTH)
established_options = response.get_json()
established_sku = next(sku for sku in established_options["skus"]
                       if sku["id"] == 301 and sku["status"] == "active")
established_version = next(version for version in established_sku["versions"]
                           if version["id"] == 311 and version["approved"] is True)
check(response.status_code == 200
      and established_sku["customer"]["id"] == 201
      and established_version["construction_version_id"] == 321,
      "S2-ESTABLISHED-1 the exact selected Customer can choose an established SKU and approved Version")
created_group_id = created["pricing_groups"][0]["id"]
with app.test_client() as client:
    established_first = client.post(f"/batches/{created_batch_id}/rows", headers=AUTH,
        json={"pricing_group_id": created_group_id, "sku_id": established_sku["id"],
              "sku_version_id": established_version["id"], "row_type": "box",
              "material_code": "ESTABLISHED-BOX-A"})
    established_second = client.post(f"/batches/{created_batch_id}/rows", headers=AUTH,
        json={"pricing_group_id": created_group_id, "sku_id": established_sku["id"],
              "sku_version_id": established_version["id"], "row_type": "box",
              "material_code": "ESTABLISHED-BOX-B"})
with app.test_client() as client:
    established_reopen = client.get(f"/batches/{created_batch_id}/workspace", headers=AUTH)
established_rows = [row for row in established_reopen.get_json()["batch"]["batch_rows"]
                    if row["material_code"].startswith("ESTABLISHED-BOX-")]
check(established_first.status_code == 201 and established_second.status_code == 201
      and established_reopen.status_code == 200 and len(established_rows) == 2
      and all(row["sku_id"] == 301 and row["sku_version_id"] == 311
              and row["effective_construction"]["version_id"] == 321
              for row in established_rows),
      "S2-ESTABLISHED-2 two established-SKU durable rows preserve SKU and Construction linkage on reopen")

ROWS["parties"].append({"id": 202, "customer_code": None, "display_name": "Second Prospect",
                        "lifecycle_state": "prospect", "status": "active"})
ROWS["party_family_memberships"].append({"party_id": 202, "family_id": 21, "is_current": True})
with app.test_client() as client:
    response = client.get("/batches/create-options", headers=AUTH)
members = response.get_json()["families"][0]["members"]
check(response.status_code == 200 and {member["id"] for member in members} == {201, 202},
      "HANDOFF-2 multi-member Family exposes both exact Customer choices")
RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "ship_to_location_id": 102, "payment_terms_days": 30,
    })
check(response.status_code == 400 and not RPC_CALLS,
      "HANDOFF-3 Family alone cannot silently substitute for a member Customer")
RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "payment_terms_days": 60,
    })
check(response.status_code == 400 and not RPC_CALLS,
      "HANDOFF-4 a Customer without a delivery Location must supply a destination")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "delivery_destination": "Pune receiving dock, Gate 2",
        "payment_terms_days": 60,
    })
check(response.status_code == 400 and not RPC_CALLS,
      "HANDOFF-4c a Customer without a Bill-to Location must supply billing detail")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "delivery_destination": "Pune receiving dock, Gate 2",
        "billing_destination": "Pune accounts office",
    })
check(response.status_code == 400 and not RPC_CALLS,
      "HANDOFF-4a calculating payment terms cannot be omitted")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "ship_to_location_id": 102,
        "billing_destination": "Pune accounts office", "payment_terms_days": 60,
    })
check(response.status_code == 422 and ROWS["batches"][-1]["customer_party_id"] == 201,
      "HANDOFF-4b an approved destination from another Customer cannot be substituted")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "delivery_destination": "Pune receiving dock, Gate 2",
        "bill_to_location_id": 101, "payment_terms_days": 60,
    })
check(response.status_code == 422 and ROWS["batches"][-1]["customer_party_id"] == 201,
      "HANDOFF-4d a Bill-to Location from another Customer cannot be substituted")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": 21, "plant_id": 7, "sector_id": 31,
        "customer_party_id": 202, "delivery_destination": "Pune receiving dock, Gate 2",
        "billing_destination": "Pune accounts office",
        "payment_terms_days": 60,
    })
missing_location_batch = response.get_json()["batch"]
check(response.status_code == 201
      and missing_location_batch["customer_party"]["display_name"] == "Second Prospect"
      and missing_location_batch["pricing_groups"][0]["payment_terms_days"] == 60
      and missing_location_batch["pricing_groups"][0]["delivery_groups"][0]["destination_text"]
          == "Pune receiving dock, Gate 2"
      and missing_location_batch["pricing_groups"][0]["delivery_groups"][0]["billing_text"]
          == "Pune accounts office"
      and missing_location_batch["pricing_groups"][0]["delivery_groups"][0]["ship_to_location_id"] is None,
      "HANDOFF-5 missing Location keeps exact Prospect and quote-specific delivery text separate")
with app.test_client() as client:
    response = client.get(f"/batches/{missing_location_batch['id']}/workspace", headers=AUTH)
reopened_missing = response.get_json()["batch"]
check(response.status_code == 200
      and reopened_missing["customer_party_id"] == 202
      and reopened_missing["pricing_groups"][0]["delivery_groups"][0]["destination_text"]
          == "Pune receiving dock, Gate 2",
      "HANDOFF-6 exact multi-member Prospect and missing delivery detail survive reopen")

with app.test_client() as client:
    response = client.post("/masters/customer-families/prospects", headers=AUTH, json={
        "display_name": "Canonical New Prospect", "sector_id": 31,
    })
created_prospect = response.get_json()
check(response.status_code == 201
      and next(row for row in ROWS["parties"] if row["id"] == created_prospect["party_id"])["status"] == "proposed"
      and next(row for row in ROWS["customer_families"] if row["id"] == created_prospect["family_id"])["status"] == "proposed",
      "HANDOFF-PROSPECT-1 canonical route creates a proposed Prospect and proposed new Family")
with app.test_client() as client:
    response = client.get("/batches/create-options", headers=AUTH)
proposed_family = next(family for family in response.get_json()["families"]
                       if family["id"] == created_prospect["family_id"])
check(response.status_code == 200
      and [member["id"] for member in proposed_family["members"]] == [created_prospect["party_id"]]
      and proposed_family["sector_ids"] == [31],
      "HANDOFF-PROSPECT-2 new proposed Family and exact proposed Prospect are selectable")
with app.test_client() as client:
    response = client.post("/batches", headers=AUTH, json={
        "family_id": created_prospect["family_id"], "plant_id": 7, "sector_id": 31,
        "customer_party_id": created_prospect["party_id"],
        "delivery_destination": "Receiving gate, Pune", "billing_destination": "Accounts, Pune",
        "payment_terms_days": 60,
    })
proposed_batch = response.get_json()["batch"]
check(response.status_code == 201
      and proposed_batch["customer_party"]["status"] == "proposed"
      and proposed_batch["family"]["status"] == "proposed"
      and proposed_batch["pricing_groups"][0]["delivery_groups"][0]["destination_text"] == "Receiving gate, Pune",
      "HANDOFF-PROSPECT-3 newly proposed Prospect creates a Batch with typed destinations")
with app.test_client() as client:
    response = client.get(f"/batches/{proposed_batch['id']}/workspace", headers=AUTH)
check(response.status_code == 200
      and response.get_json()["batch"]["customer_party_id"] == created_prospect["party_id"],
      "HANDOFF-PROSPECT-4 proposed Prospect identity survives reopen")

# A canonical newly created Prospect must also be able to add several durable
# rows without being silently recast as an active Customer or Family.
ROWS["skus"].append({"id": 304, "plant_id": 7, "party_id": created_prospect["party_id"],
                     "plant_item_code": None, "status": "proposed",
                     "replacement_sku_id": None, "content_version": 1})
ROWS["sku_versions"].append({"id": 316, "sku_id": 304, "plant_id": 7, "version_no": 1,
                             "construction_version_id": 321, "is_price_driving": True,
                             "length_mm": 400, "width_mm": 300, "height_mm": 250,
                             "box_type": "RSC", "ups": 1, "item_name": "New carton",
                             "item_short_name": "Carton", "spec_bs": None,
                             "spec_bct": None, "spec_ect": None, "approved_at": None})
with app.test_client() as client:
    response = client.get(f"/batches/{proposed_batch['id']}/row-options", headers=AUTH)
check(response.status_code == 200
      and [sku["id"] for sku in response.get_json()["skus"]] == [304]
      and response.get_json()["skus"][0]["versions"][0]["item_name"] == "New carton"
      and response.get_json()["skus"][0]["versions"][0]["approved"] is False
      and response.get_json()["selection_contract"]
          == "non_withdrawn_sku_version_with_plant_adopted_construction",
      "S2-PROSPECT-1 proposed Prospect can select its proposed SKU and adopted version")
proposed_group_id = proposed_batch["pricing_groups"][0]["id"]
with app.test_client() as client:
    first = client.post(f"/batches/{proposed_batch['id']}/rows", headers=AUTH,
                        json={"pricing_group_id": proposed_group_id, "sku_id": 304,
                              "sku_version_id": 316, "row_type": "box",
                              "material_code": "PROSPECT-BOX-A"})
    second = client.post(f"/batches/{proposed_batch['id']}/rows", headers=AUTH,
                         json={"pricing_group_id": proposed_group_id, "sku_id": 304,
                               "sku_version_id": 316, "row_type": "box",
                               "material_code": "PROSPECT-BOX-B"})
with app.test_client() as client:
    reopened = client.get(f"/batches/{proposed_batch['id']}/workspace", headers=AUTH)
check(first.status_code == 201 and second.status_code == 201
      and reopened.status_code == 200
      and {row["material_code"] for row in reopened.get_json()["batch"]["batch_rows"]}
      == {"PROSPECT-BOX-A", "PROSPECT-BOX-B"},
      "S2-PROSPECT-2 two durable rows for the exact proposed Prospect survive reopen")

ROWS["parties"].append({"id": 299, "customer_code": None, "display_name": "Inactive Prospect",
                        "lifecycle_state": "prospect", "status": "inactive"})
ROWS["party_family_memberships"].append({"party_id": 299, "family_id": 21, "is_current": True})
with app.test_client() as client:
    response = client.get("/batches/create-options", headers=AUTH)
check(all(member["id"] != 299 for family in response.get_json()["families"]
          for member in family["members"]),
      "HANDOFF-PROSPECT-5 inactive identities stay out of the picker")

with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/heartbeat", headers=AUTH)
check(response.status_code == 200
      and RPC_CALLS[-1] == ("tok-u4", "heartbeat_batch_lock", {"p_batch": created_batch_id}),
      "U4-LOCK-1 the active Maker lock heartbeat uses the governed RPC")

with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/release", headers=AUTH)
check(response.status_code == 200
      and RPC_CALLS[-1] == ("tok-u4", "release_batch_lock", {"p_batch": created_batch_id}),
      "U4-LOCK-2 explicitly closing a Batch releases its lock through the governed RPC")

with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/acquire", headers=AUTH)
reacquired = response.get_json()["batch"]
check(response.status_code == 200 and reacquired["caller_holds_lock"] is True
      and RPC_CALLS[-1] == ("tok-u4", "acquire_batch_lock", {"p_batch": created_batch_id}),
      "U4-LOCK-3 an available Batch lock is reacquired and read back before editing")

with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/reclaim",
                           json={"expected_holder_id": 99})
check(response.status_code == 401,
      "U4-LOCK-4 anonymous stale-lock reclaim is refused")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/reclaim", headers=AUTH, json={})
check(response.status_code == 400 and not RPC_CALLS,
      "U4-LOCK-5 reclaim requires the exact observed holder before calling the database")

created_lock = next(row for row in ROWS["batch_edit_locks"]
                    if row["batch_id"] == created_batch_id)
created_lock.update({"holder_user_id": 99, "heartbeat_at": "2026-09-12T08:00:00Z"})
with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/reclaim", headers=AUTH,
                           json={"expected_holder_id": 98})
check(response.status_code == 409 and created_lock["holder_user_id"] == 99,
      "U4-LOCK-6 reclaim loses safely when the observed holder has already changed")

with app.test_client() as client:
    response = client.post(f"/batches/{created_batch_id}/lock/reclaim", headers=AUTH,
                           json={"expected_holder_id": 99})
reclaimed = response.get_json()["batch"]
check(response.status_code == 200 and reclaimed["caller_holds_lock"] is True
      and RPC_CALLS[-1] == ("tok-u4", "reclaim_batch_lock", {
          "p_batch": created_batch_id, "p_expected_holder": 99,
      }), "U4-LOCK-7 owner reclaim preserves observed-holder race protection and reads back ownership")

CALLS.clear()
with app.test_client() as client:
    response = client.get("/batches/pricing-basis", headers=AUTH)
check(response.status_code == 400 and not CALLS,
      "U4-PB-2 missing permanent reference is refused before a database read")

with app.test_client() as client:
    response = client.get("/batches/pricing-basis?reference=NAG%2FBAT%2F2026-27%2F00071", headers=AUTH)
payload = response.get_json()
check(response.status_code == 200 and payload["batch"]["pricing_date"] == "2026-09-11",
      "U4-PB-3 persisted Pricing Date is loaded")
check(payload["batch"]["pricing_basis_release_id"] == 11
      and payload["batch"]["pricing_basis_is_deliberate"] is False,
      "U4-PB-4 persisted Release identity and selection mode are loaded")
check(payload["batch"]["plant"]["plant_code"] == "NAG"
      and payload["batch"]["pricing_basis_release"]["id"] == 11,
      "U4-PB-5 exact plant and caller-visible Release identities are returned")
check(all(call[0] == "tok-u4" for call in CALLS),
      "U4-PB-6 every Batch, plant and Release read carries the caller token")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches/71/pricing-basis", headers=AUTH, json={
        "expected_content_version": 7, "pricing_date": "2026-02-30", "release_id": 12,
    })
check(response.status_code == 400 and not RPC_CALLS,
      "U4-PB-7 impossible Pricing Date is refused before the governed RPC")

with app.test_client() as client:
    response = client.post("/batches/71/pricing-basis", headers=AUTH, json={
        "expected_content_version": 7, "pricing_date": "2026-10-15",
    })
check(response.status_code == 400 and not RPC_CALLS,
      "U4-PB-8 omitted Release instruction cannot silently revert to automatic")

with app.test_client() as client:
    response = client.post("/batches/71/pricing-basis", headers=AUTH, json={
        "expected_content_version": 7, "pricing_date": "2026-10-15", "release_id": 12,
    })
payload = response.get_json()
check(response.status_code == 200 and RPC_CALLS[-1] == ("tok-u4", "set_batch_pricing_basis", {
    "p_batch": 71, "p_expected_content_version": 7,
    "p_pricing_date": "2026-10-15", "p_release": 12,
}), "U4-PB-9 deliberate alternative uses the exact governed RPC contract")
check(payload["batch"]["pricing_basis_release_id"] == 12
      and payload["batch"]["pricing_basis_is_deliberate"] is True
      and payload["batch"]["content_version"] == 8,
      "U4-PB-10 mutation response reads back the durable deliberate selection")

with app.test_client() as client:
    reopened = client.get("/batches/71/pricing-basis", headers=AUTH).get_json()["batch"]
check(reopened["pricing_date"] == "2026-10-15"
      and reopened["pricing_basis_release_id"] == 12
      and reopened["pricing_basis_is_deliberate"] is True,
      "U4-PB-11 reopening returns the same persisted selection")

with app.test_client() as client:
    response = client.post("/batches/71/pricing-basis", headers=AUTH, json={
        "expected_content_version": 8, "pricing_date": "2026-09-11", "release_id": None,
    })
check(response.status_code == 200 and RPC_CALLS[-1][2]["p_release"] is None,
      "U4-PB-12 automatic re-resolution is an explicit null RPC argument")
check(ROWS["batches"][0]["pricing_basis_is_deliberate"] is False,
      "U4-PB-13 governed automatic mode is read back without a direct table update")

CALLS.clear()
with app.test_client() as client:
    response = client.get("/batches/71/workspace", headers=AUTH)
workspace = response.get_json()["batch"]
check(response.status_code == 200 and workspace["family"]["group_customer_code"] == "FAM-021"
      and workspace["owner"]["display_name"] == "Fixture Maker",
      "U4-WS-1 workspace returns exact durable Family and owner identities")
check([membership["sector_id"] for membership in workspace["family_sectors"]] == [31, 32]
      and workspace["family_sectors"][0]["sector"]["sector_code"] == "PIZZA"
      and workspace["sector_id"] == 31,
      "U4-WS-1a workspace distinguishes all Family Sectors from the one selected Batch Sector")
check(workspace["current_profile"]["waste_cbb_pct"] is None
      and workspace["current_profile"]["waste_pp_pct"] == 0,
      "U4-WS-2 current profile preserves blank and explicit zero distinctly")
check(workspace["edit_lock"]["holder"]["id"] == 4
      and workspace["collaborators"][0]["user"]["id"] == 5,
      "U4-WS-3 caller-visible lock holder and collaborator identities are explicit")
check(workspace["pricing_groups"][0]["delivery_groups"][0]["bill_to_location"]["id"] == 101
      and workspace["pricing_groups"][0]["delivery_groups"][0]["ship_to_location"]["id"] == 102,
      "U4-WS-4 Pricing and Delivery Groups retain separate Bill-to and Ship-to identities")
check(workspace["batch_rows"][0]["sku"]["plant_item_code"] == "NAG-SKU-301"
      and workspace["batch_rows"][0]["sku_version"]["id"] == 311
      and workspace["batch_rows"][0]["effective_construction"]["origin"] == "sku_version"
      and workspace["batch_rows"][0]["effective_construction"]["construction"]["construction_code"] == "5P-180-22",
      "U4-WS-4a durable rows retain exact SKU, Version and authoritative Construction identities")
check(all(call[0] == "tok-u4" for call in CALLS),
      "U4-WS-5 every workspace section read carries the caller token")

DENIED_TABLES.add("batch_collaborators")
with app.test_client() as client:
    response = client.get("/batches/71/workspace", headers=AUTH)
denied_workspace = response.get_json()["batch"]
check(response.status_code == 200 and denied_workspace["details_partial"] is True
      and "collaborators" in denied_workspace["denied_sections"]
      and denied_workspace["collaborators"] == [],
      "U4-WS-6 a denied optional section is explicit and no hidden data is invented")
DENIED_TABLES.clear()

with app.test_client() as client:
    response = client.get("/batches/999/workspace", headers=AUTH)
check(response.status_code == 404,
      "U4-WS-7 an invisible Batch remains indistinguishable from a missing Batch")

with app.test_client() as client:
    response = client.post("/batches/71/delivery-groups")
check(response.status_code == 401,
      "U4-DG-1 anonymous Delivery Group creation is refused")

TABLE_WRITES.clear()
with app.test_client() as client:
    response = client.patch("/batches/71/delivery-groups/91", headers=AUTH, json={
        "pricing_group_id": 81, "label": "Location 1",
        "bill_to_location_id": 101, "ship_to_location_id": 102,
    })
check(response.status_code == 200
      and ROWS["delivery_groups"][0]["label"] == "Location 1",
      "U4-DG-2 the default route is completed with distinct eligible Bill-to and Ship-to identities")

with app.test_client() as client:
    response = client.post("/batches/71/delivery-groups", headers=AUTH, json={
        "pricing_group_id": 81, "label": "Location 2",
        "bill_to_location_id": 101, "ship_to_location_id": 103,
    })
created_workspace = response.get_json()["batch"]
created_routes = created_workspace["pricing_groups"][0]["delivery_groups"]
location_two = next(route for route in created_routes if route["label"] == "Location 2")
check(response.status_code == 201 and location_two["ship_to_location"]["id"] == 103,
      "U4-DG-3 Location 2 is added beneath the same Pricing Group")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/freight-basis", headers=AUTH, json={
        "expected_content_version": 2, "delivery_group_id": location_two["id"],
    })
basis_workspace = response.get_json()["batch"]
basis_group = basis_workspace["pricing_groups"][0]
check(response.status_code == 200
      and basis_group["freight_basis_delivery_group_id"] == location_two["id"]
      and basis_group["content_version"] == 3,
      "U4-DG-4 freight basis changes with the Pricing Group CAS token")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.post("/batches/71/delivery-groups", headers=AUTH, json={
        "pricing_group_id": 81, "label": "Invalid route",
        "bill_to_location_id": 101, "ship_to_location_id": 101,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-DG-5 a Location without Ship-to eligibility is refused before writing")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/freight-basis", headers=AUTH, json={
        "expected_content_version": 2, "delivery_group_id": 91,
    })
check(response.status_code == 409 and response.get_json()["error_code"] == "STALE_VERSION",
      "U4-DG-6 a stale freight-basis change is refused")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", json={})
check(response.status_code == 401,
      "U4-PG-1 anonymous Pricing Group commercial-term editing is refused")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 3, "label": "Renewal", "freight_mode": "manual",
        "freight_manual_value": None, "payment_terms_days": 60,
        "payment_terms_text": "60 days from invoice", "interest_override_pct": None,
        "interest_override_reason": None,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-PG-2 manual freight cannot be saved without an explicit value")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 3, "label": "Renewal", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 35,
        "payment_terms_text": None, "interest_override_pct": None,
        "interest_override_reason": None,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-PG-3 calculating Payment Terms remain the closed 30/45/60/90-day domain")

# An explicit manual statement is the governed U4 restatement of temporary
# higher-priority Batch freight, so the two temporary columns are retired in
# the same atomic CAS write. Zero must survive as a deliberate value.
ROWS["pricing_groups"][0].update({
    "legacy_freight_value": 2.75, "legacy_freight_source": "legacy_batch",
})
with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 3, "label": "Renewal", "freight_mode": "manual",
        "freight_manual_value": 0, "payment_terms_days": 60,
        "payment_terms_text": "60 days from invoice", "interest_override_pct": 0,
        "interest_override_reason": "Interest waived for this renewal",
    })
commercial_group = response.get_json()["batch"]["pricing_groups"][0]
commercial_write = TABLE_WRITES[-1]
check(response.status_code == 200 and commercial_group["content_version"] == 4
      and commercial_group["freight_manual_value"] == 0
      and commercial_group["interest_override_pct"] == 0,
      "U4-PG-4 deliberate zero freight and Interest persist through the Pricing Group CAS token")
check(commercial_group["interest_override_derived_pct"] == 1.0
      and commercial_write[3]["interest_override_derived_pct"] == 1.0
      and commercial_group["interest_override_reason"] == "Interest waived for this renewal",
      "U4-PG-5 the current approved annual basis derives 1.000% for 60 days and the differing override keeps its reason")
check(commercial_group["legacy_freight_value"] is None
      and commercial_group["legacy_freight_source"] is None,
      "U4-PG-6 governed manual freight atomically retires the temporary legacy-Batch tier")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 4, "label": "Renewal ex works",
        "freight_mode": "ex_factory", "freight_manual_value": 8,
        "payment_terms_days": None, "payment_terms_text": None,
        "interest_override_pct": None, "interest_override_reason": "discarded residue",
    })
blank_group = response.get_json()["batch"]["pricing_groups"][0]
check(response.status_code == 200 and blank_group["content_version"] == 5
      and blank_group["freight_manual_value"] is None
      and blank_group["freight_basis_delivery_group_id"] is None
      and blank_group["interest_override_pct"] is None
      and blank_group["interest_override_reason"] is None,
      "U4-PG-7 ex-factory clears inactive freight inputs and blank Interest clears all override residue")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 4, "label": "Stale", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 30,
        "payment_terms_text": None, "interest_override_pct": None,
        "interest_override_reason": None,
    })
check(response.status_code == 409 and response.get_json()["error_code"] == "STALE_VERSION",
      "U4-PG-8 a stale commercial-terms replacement is refused")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 5, "label": "Standard", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 30,
        "payment_terms_text": None, "interest_override_pct": 0.5,
        "interest_override_reason": None,
    })
check(response.status_code == 200
      and response.get_json()["batch"]["pricing_groups"][0]["interest_override_derived_pct"] == 0.5,
      "U4-PG-9 an override equal to derived Interest does not invent a reason")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 6, "label": "Standard", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 30,
        "payment_terms_text": None, "interest_override_pct": 0.9,
        "interest_override_reason": None,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-PG-10 an Interest override differing from the derived percentage requires a reason")

ROWS["batches"][0]["pricing_basis_release_id"] = None
with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 6, "label": "Standard", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 30,
        "payment_terms_text": None, "interest_override_pct": 0.5,
        "interest_override_reason": None,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-PG-10a an Interest override is never compared with a guessed or hard-coded annual basis")
ROWS["batches"][0]["pricing_basis_release_id"] = 11

DENIED_ACTIONS.add(("pricing_groups", "update"))
with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81", headers=AUTH, json={
        "expected_content_version": 6, "label": "Denied", "freight_mode": "master",
        "freight_manual_value": None, "payment_terms_days": 30,
        "payment_terms_text": None, "interest_override_pct": None,
        "interest_override_reason": None,
    })
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-PG-11 lock/RLS denial is not reported as a successful commercial-term edit")
DENIED_ACTIONS.clear()
check(commercial_write[0] == "tok-u4",
      "U4-PG-12 the Pricing Group write carries the caller token")

DENIED_TABLES.add("delivery_groups")
with app.test_client() as client:
    response = client.post("/batches/71/delivery-groups", headers=AUTH, json={
        "pricing_group_id": 81, "label": "Denied route",
        "bill_to_location_id": 101, "ship_to_location_id": 103,
    })
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-DG-7 lock/RLS denial is not reported as a successful route addition")
DENIED_TABLES.clear()
check(TABLE_WRITES and all(write[0] == "tok-u4" for write in TABLE_WRITES),
      "U4-DG-8 every Delivery Group and freight-basis write carries the caller token")

with app.test_client() as client:
    response = client.post("/batches/71/pricing-groups", json={"label": "Export"})
check(response.status_code == 401,
      "U4-PGL-1 anonymous Pricing Group creation is refused")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.post("/batches/71/pricing-groups", headers=AUTH, json={"label": 42})
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-PGL-2 Pricing Group creation refuses non-text labels before writing")

with app.test_client() as client:
    response = client.post("/batches/71/pricing-groups", headers=AUTH, json={"label": "Export"})
new_group_workspace = response.get_json()["batch"]
new_group = next(group for group in new_group_workspace["pricing_groups"]
                 if group["batch_id"] == 71 and group["label"] == "Export")
check(response.status_code == 201 and new_group["status"] == "active"
      and new_group["content_version"] == 1 and new_group["delivery_groups"] == [],
      "U4-PGL-3 a second empty Pricing Group can be drafted for a genuinely different price")

DENIED_ACTIONS.add(("pricing_groups", "insert"))
with app.test_client() as client:
    response = client.post("/batches/71/pricing-groups", headers=AUTH, json={"label": "Denied"})
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-PGL-4 lock/RLS denial is not reported as a successful Pricing Group creation")
DENIED_ACTIONS.clear()

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/freight-basis", headers=AUTH, json={
        "expected_content_version": 6, "delivery_group_id": 91,
    })
check(response.status_code == 200,
      "U4-PGL-5 the fixture reselects an explicit freight basis before lifecycle checks")

with app.test_client() as client:
    response = client.patch("/batches/71/delivery-groups/91/status", headers=AUTH, json={
        "pricing_group_id": 81, "status": "removed",
    })
removed_route_group = next(group for group in response.get_json()["batch"]["pricing_groups"]
                           if group["id"] == 81)
removed_route = next(route for route in removed_route_group["delivery_groups"] if route["id"] == 91)
check(response.status_code == 200 and removed_route["status"] == "removed"
      and removed_route_group["freight_basis_delivery_group_id"] == 91,
      "U4-PGL-6 removing the selected route preserves the explicit basis identity so readiness blocks instead of falling back")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/freight-basis", headers=AUTH, json={
        "expected_content_version": 7, "delivery_group_id": 91,
    })
check(response.status_code == 400,
      "U4-PGL-7 a removed Delivery Group cannot be selected as a freight basis")

with app.test_client() as client:
    response = client.patch("/batches/71/delivery-groups/91/status", headers=AUTH, json={
        "pricing_group_id": 81, "status": "active",
    })
check(response.status_code == 200
      and next(route for route in response.get_json()["batch"]["pricing_groups"][0]["delivery_groups"]
               if route["id"] == 91)["status"] == "active",
      "U4-PGL-8 the same Delivery Group identity can be restored")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/status", headers=AUTH, json={
        "expected_content_version": 7, "status": "removed",
    })
removed_group_workspace = response.get_json()["batch"]
removed_group = next(group for group in removed_group_workspace["pricing_groups"] if group["id"] == 81)
check(response.status_code == 200 and removed_group["status"] == "removed"
      and removed_group["content_version"] == 8
      and any(row["status"] == "active" and row["pricing_group_id"] == 81
              for row in removed_group_workspace["batch_rows"]),
      "U4-PGL-9 Pricing Group removal is reversible and preserves assigned active rows for explicit repair")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/status", headers=AUTH, json={
        "expected_content_version": 7, "status": "active",
    })
check(response.status_code == 409 and response.get_json()["error_code"] == "STALE_VERSION",
      "U4-PGL-10 stale Pricing Group restore loses without overwriting lifecycle state")

with app.test_client() as client:
    response = client.patch("/batches/71/pricing-groups/81/status", headers=AUTH, json={
        "expected_content_version": 8, "status": "active",
    })
restored_group = next(group for group in response.get_json()["batch"]["pricing_groups"]
                      if group["id"] == 81)
check(response.status_code == 200 and restored_group["status"] == "active"
      and restored_group["content_version"] == 9,
      "U4-PGL-11 restore preserves Pricing Group identity and advances the same CAS token")

DENIED_ACTIONS.add(("delivery_groups", "update"))
with app.test_client() as client:
    response = client.patch("/batches/71/delivery-groups/91/status", headers=AUTH, json={
        "pricing_group_id": 81, "status": "removed",
    })
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-PGL-12 Delivery Group lifecycle remains governed by the caller lock/RLS boundary")
DENIED_ACTIONS.clear()

with app.test_client() as client:
    response = client.get("/batches/71/row-options", headers=AUTH)
row_options = response.get_json()
check(response.status_code == 200
      and [sku["id"] for sku in row_options["skus"]] == [301]
      and [version["id"] for version in row_options["skus"][0]["versions"]] == [313, 311]
      and [version["approved"] for version in row_options["skus"][0]["versions"]] == [False, True]
      and row_options["selection_contract"]
          == "non_withdrawn_sku_version_with_plant_adopted_construction",
      "U4-ROW-1 row options retain the Batch Family/plant SKU and its ADOPTED versions, unapproved ones "
      "included and labelled; a withdrawn SKU is never offered and the contract states that rule")
check(row_options["skus"][0]["customer"]["customer_code"] == "CUST-201"
      and row_options["skus"][0]["external_references"][0]["reference_value"] == "CUST-BOX-301"
      and row_options["skus"][0]["versions"][0]["construction"]["id"] == 331,
      "U4-ROW-2 Customer, alias and Construction identities are explicit and never parsed from labels")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.post("/batches/71/rows", headers=AUTH, json={
        "pricing_group_id": 81, "sku_id": 301, "sku_version_id": 312,
        "row_type": "box", "material_code": "SHOULD-NOT-WRITE",
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-ROW-3 a SKU Version on an unadopted Construction is refused before writing")

with app.test_client() as client:
    response = client.post("/batches/71/rows", headers=AUTH, json={
        "pricing_group_id": 81, "sku_id": 301, "sku_version_id": 311,
        "row_type": "box", "material_code": "NAG-SKU-301-B",
        "waste_override_pct": 0, "margin_override_pct": None,
        "conv_override_rate": 7, "freight_override": 2,
        "addon_printing": 0, "addon_coating": None, "addon_other": 12.5,
        "fluting_bcf": 0,
    })
created_rows = response.get_json()["batch"]["batch_rows"]
created_row = next(row for row in created_rows if row["material_code"] == "NAG-SKU-301-B")
check(response.status_code == 201 and created_row["plant_id"] == 7
      and created_row["sku_id"] == 301 and created_row["sku_version_id"] == 311
      and created_row["addon_printing"] == 0 and created_row["addon_coating"] is None
      and created_row["addon_other"] == 12.5 and created_row["fluting_bcf"] == 0,
      "U4-ROW-4 a durable row and its blank/zero/value add-on inputs are inserted under the lock")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": created_row["content_version"],
        "pricing_group_id": new_group["id"], "sku_version_id": 311,
        "row_type": "plate", "material_code": "NAG-PLATE-301",
    })
updated_row = next(row for row in response.get_json()["batch"]["batch_rows"]
                   if row["id"] == created_row["id"])
check(response.status_code == 200 and updated_row["row_type"] == "plate"
      and updated_row["material_code"] == "NAG-PLATE-301"
      and updated_row["pricing_group_id"] == new_group["id"]
      and updated_row["waste_override_pct"] == 0
      and updated_row["margin_override_pct"] is None
      and updated_row["conv_override_rate"] == 7
      and updated_row["freight_override"] == 2
      and updated_row["addon_printing"] == 0
      and updated_row["addon_coating"] is None
      and updated_row["addon_other"] == 12.5
      and updated_row["fluting_bcf"] == 0
      and updated_row["content_version"] == created_row["content_version"] + 1,
      "U4-ROW-5 row editing visibly reassigns its Pricing Group with CAS while preserving omitted inputs distinctly")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": updated_row["content_version"],
        "pricing_group_id": 81, "sku_version_id": 311,
        "row_type": "plate", "material_code": "INVALID-NEGATIVE",
        "margin_override_pct": -0.001,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-ROW-5a a negative row override is refused before writing")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": updated_row["content_version"],
        "pricing_group_id": 81, "sku_version_id": 311,
        "row_type": "plate", "material_code": "INVALID-BCF",
        "fluting_bcf": 0.3001,
    })
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-ROW-5b fluting BCF outside the governed 0..0.30 range is refused before writing")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": created_row["content_version"],
        "pricing_group_id": 81, "sku_version_id": 311,
        "row_type": "box", "material_code": "STALE",
    })
check(response.status_code == 409 and response.get_json()["error_code"] == "STALE_VERSION",
      "U4-ROW-6 a stale row revision is refused without overwriting current content")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}/status", headers=AUTH, json={
        "expected_content_version": updated_row["content_version"], "status": "removed",
    })
removed_row = next(row for row in response.get_json()["batch"]["batch_rows"]
                   if row["id"] == created_row["id"])
check(response.status_code == 200 and removed_row["status"] == "removed"
      and removed_row["content_version"] == updated_row["content_version"] + 1,
      "U4-ROW-6a removing a row is reversible, lock-governed and content-versioned")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": removed_row["content_version"],
        "pricing_group_id": 81, "sku_version_id": 311,
        "row_type": "plate", "material_code": "REMOVED-CANNOT-EDIT",
    })
check(response.status_code == 422 and response.get_json()["error_code"] == "TRANSITION_NOT_ALLOWED",
      "U4-ROW-6b a removed row cannot be edited as though it were active")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}/status", headers=AUTH, json={
        "expected_content_version": updated_row["content_version"], "status": "active",
    })
check(response.status_code == 409 and response.get_json()["error_code"] == "STALE_VERSION",
      "U4-ROW-6c stale restore loses without changing the removed row")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}/status", headers=AUTH, json={
        "expected_content_version": removed_row["content_version"], "status": "active",
    })
restored_row = next(row for row in response.get_json()["batch"]["batch_rows"]
                    if row["id"] == created_row["id"])
check(response.status_code == 200 and restored_row["status"] == "active"
      and restored_row["content_version"] == removed_row["content_version"] + 1,
      "U4-ROW-6d restore preserves row identity and advances the same CAS token")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": restored_row["content_version"],
        "pricing_group_id": restored_row["pricing_group_id"], "sku_version_id": 311,
        "row_type": restored_row["row_type"], "material_code": restored_row["material_code"],
        "volume": 5000, "sales_moq": 0,
    })
quantity_row = next(row for row in response.get_json()["batch"]["batch_rows"]
                    if row["id"] == created_row["id"])
check(response.status_code == 200 and quantity_row["volume"] == 5000
      and quantity_row["sales_moq"] == 0 and quantity_row["waste_override_pct"] == 0
      and quantity_row["addon_other"] == 12.5 and quantity_row["fluting_bcf"] == 0
      and quantity_row["content_version"] == restored_row["content_version"] + 1,
      "U4-ROW-6e S3 volume and MOQ are row-owned inputs: a value and an explicit zero are written, omitted inputs kept")

with app.test_client() as client:
    response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
        "expected_content_version": quantity_row["content_version"],
        "pricing_group_id": quantity_row["pricing_group_id"], "sku_version_id": 311,
        "row_type": quantity_row["row_type"], "material_code": quantity_row["material_code"],
        "sales_moq": None,
    })
cleared_row = next(row for row in response.get_json()["batch"]["batch_rows"]
                   if row["id"] == created_row["id"])
check(response.status_code == 200 and cleared_row["sales_moq"] is None and cleared_row["volume"] == 5000,
      "U4-ROW-6f S3 a blank MOQ clears to blank (not zero) and an omitted volume is preserved")

for bad in (-1, 12.5, "many", True):
    writes_before_invalid = len(TABLE_WRITES)
    with app.test_client() as client:
        response = client.patch(f"/batches/71/rows/{created_row['id']}", headers=AUTH, json={
            "expected_content_version": cleared_row["content_version"],
            "pricing_group_id": cleared_row["pricing_group_id"], "sku_version_id": 311,
            "row_type": cleared_row["row_type"], "material_code": cleared_row["material_code"],
            "volume": bad,
        })
    check(response.status_code == 400 and response.get_json()["error_code"] == "INVALID_INPUT"
          and len(TABLE_WRITES) == writes_before_invalid,
          f"U4-ROW-6g S3 volume {bad!r} is refused before writing: whole non-negative numbers only")

DENIED_TABLES.add("batch_rows")
with app.test_client() as client:
    response = client.post("/batches/71/rows", headers=AUTH, json={
        "pricing_group_id": 81, "sku_id": 301, "sku_version_id": 311,
        "row_type": "box", "material_code": "DENIED",
    })
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-ROW-7 lock/RLS denial cannot be presented as a successful durable row")
DENIED_TABLES.clear()
check(all(write[0] == "tok-u4" for write in TABLE_WRITES),
      "U4-ROW-8 every durable row write carries the genuine caller token")

with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
effective = response.get_json()
check(response.status_code == 200
      and effective["freshness"] == "not_calculated"
      and effective["resolution"]["effective_inputs"]["resolved"]["waste"] == {
          "value": 0, "source": "row"}
      and effective["mutation"] == "none"
      and effective["governed_calculate"] == "available",
      "U4-EFFECTIVE-1 caller-authorized resolution is read without persisting a calculation")
check(RPC_CALLS[-1] == ("tok-u4", "calculate_inputs", {"p_batch_row_id": 351}),
      "U4-EFFECTIVE-2 effective inputs use the existing caller-token gatherer for the exact row")

ROWS["batch_calculations"][:] = [{
    "id": 901, "batch_row_id": 351, "batch_id": 71,
    "calculation_fingerprint": "calc-fp-current",
    "presentation_fingerprint": "present-fp-current",
    "engine_version": "engine/qe1-7c2ceac1972460ba", "schema_version": "s9",
    "computed_by": 4, "computed_at": "2026-09-12T10:00:00Z",
}]
with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
check(response.get_json()["freshness"] == "fresh",
      "U4-EFFECTIVE-3 matching calculation and presentation fingerprints are fresh")

ROWS["batch_calculations"][0]["presentation_fingerprint"] = "present-fp-older"
with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
check(response.get_json()["freshness"] == "needs_send_only",
      "U4-EFFECTIVE-4 presentation-only change is distinguished from calculation staleness")

ROWS["batch_calculations"][0]["calculation_fingerprint"] = "calc-fp-older"
with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
check(response.get_json()["freshness"] == "calculation_stale",
      "U4-EFFECTIVE-5 calculation-input change is explicitly stale")

DENIED_TABLES.add("batch_calculations")
with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
denied_effective = response.get_json()
check(response.status_code == 200 and denied_effective["freshness"] == "unknown"
      and denied_effective["calculation_details_denied"] is True
      and denied_effective["calculation"] is None,
      "U4-EFFECTIVE-6 denied calculation evidence never becomes a false not-calculated claim")
DENIED_TABLES.clear()

CALCULATE_INPUTS_ERROR = "PT422"
with app.test_client() as client:
    response = client.get("/batches/71/rows/351/effective-inputs", headers=AUTH)
check(response.status_code == 422 and response.get_json()["error_code"] == "CALCULATION_NOT_READY",
      "U4-EFFECTIVE-7 unresolved governed inputs return a caller-visible not-ready state")
CALCULATE_INPUTS_ERROR = None

# ── S3 · one authoritative readiness result ─────────────────────────────────
def readiness():
    with app.test_client() as client:
        response = client.get("/batches/71/readiness", headers=AUTH)
    return response.status_code, response.get_json()

active_ids = sorted(row["id"] for row in ROWS["batch_rows"]
                    if row["batch_id"] == 71 and row["status"] == "active")
other_ids = [row_id for row_id in active_ids if row_id != 351]
ROWS["batch_calculations"][0].update(calculation_fingerprint="calc-fp-current",
                                     presentation_fingerprint="present-fp-current")
rpc_before, writes_before = len(RPC_CALLS), len(TABLE_WRITES)
status, ready = readiness()
check(status == 200 and len(active_ids) >= 2
      and sorted(row["row_id"] for row in ready["rows"]) == active_ids
      and [call for call in RPC_CALLS[rpc_before:]] == [
          ("tok-u4", "calculate_inputs", {"p_batch_row_id": row_id}) for row_id in active_ids]
      and len(TABLE_WRITES) == writes_before and ready["mutation"] == "none",
      "S3-READY-1 readiness evaluates EVERY active row through the caller-token gatherer and writes nothing")
by_row = {row["row_id"]: row for row in ready["rows"]}
check(by_row[351]["freshness"] == "fresh" and by_row[351]["content_version"] is not None
      and all(by_row[row_id]["freshness"] == "not_calculated" for row_id in other_ids)
      and ready["can_calculate"] is True and ready["can_send"] is False
      and sorted(item["row_id"] for item in ready["blockers"]
                 if item["code"] == "not_calculated") == other_ids
      and all(item["field"] == "calculation" and item["blocks"] == ["send"]
              for item in ready["blockers"] if item["code"] == "not_calculated"),
      "S3-READY-2 one fresh row cannot pass a multi-row Batch: each uncalculated row is its own Send blocker")

CALCULATE_INPUTS_ROW_ERRORS[other_ids[0]] = ("PT422", "dimensions_incomplete")
status, ready = readiness()
dims = [item for item in ready["blockers"] if item["code"] == "dimensions_incomplete"]
check(status == 200 and len(dims) == 1 and dims[0]["row_id"] == other_ids[0]
      and dims[0]["scope"] == "row" and dims[0]["field"] == "dimensions"
      and dims[0]["blocks"] == ["calculate", "send"] and ready["can_calculate"] is False
      and next(row for row in ready["rows"] if row["row_id"] == other_ids[0])["status"] == "blocked",
      "S3-READY-3 a gatherer refusal names its exact row and field and blocks Calculate")

CALCULATE_INPUTS_ROW_ERRORS[other_ids[0]] = ("PT422", "relation secret_table: detail nobody should see")
status, ready = readiness()
check(status == 200 and "secret" not in json.dumps(ready)
      and any(item["code"] == "not_ready" and item["row_id"] == other_ids[0] for item in ready["blockers"]),
      "S3-READY-4 only allow-listed reason codes leave the server; other database text never does")

CALCULATE_INPUTS_ROW_ERRORS.clear()
CALCULATE_INPUTS_ROW_ERRORS.update({row_id: ("PT422", "pricing_basis_absent") for row_id in active_ids})
status, ready = readiness()
basis = [item for item in ready["blockers"] if item["code"] == "pricing_basis_absent"]
check(status == 200 and len(basis) == 1 and basis[0]["scope"] == "batch"
      and basis[0]["field"] == "pricing_basis" and basis[0]["row_id"] is None,
      "S3-READY-5 a Batch-level refusal is reported once, against the Batch field, not per row")
CALCULATE_INPUTS_ROW_ERRORS.clear()

held_lock = ROWS["batch_edit_locks"][0]["holder_user_id"]
ROWS["batch_edit_locks"][0]["holder_user_id"] = 5
status, ready = readiness()
check(status == 200 and any(item["code"] == "lock_required" and item["field"] == "lock"
                            for item in ready["blockers"])
      and ready["can_calculate"] is False and ready["can_send"] is False,
      "S3-READY-6 without the Batch edit lock readiness says so instead of offering Calculate")
ROWS["batch_edit_locks"][0]["holder_user_id"] = held_lock

ROWS["batch_calculations"][0].update(calculation_fingerprint="calc-fp-older",
                                     presentation_fingerprint="present-fp-current")
status, ready = readiness()
check(status == 200 and any(item["code"] == "calculation_stale" and item["row_id"] == 351
                            and item["field"] == "calculation" and item["blocks"] == ["send"]
                            for item in ready["blockers"])
      and ready["can_calculate"] is True and ready["can_send"] is False,
      "S3-READY-7 a governed edit/fingerprint change makes the exact row visibly stale for Send")

ROWS["batch_calculations"][0].update(calculation_fingerprint="calc-fp-current",
                                     presentation_fingerprint="present-fp-older")
status, ready = readiness()
row_351 = next(row for row in ready["rows"] if row["row_id"] == 351)
check(status == 200 and row_351["freshness"] == "needs_send_only"
      and not any(item["row_id"] == 351 and item["code"] == "needs_send_only"
                  for item in ready["blockers"]),
      "S3-READY-8 presentation-only divergence remains Send-compatible and is not invented as a blocker")

CALCULATE_INPUTS_ROW_ERRORS[other_ids[0]] = ("42501", "private authorization detail")
status, ready = readiness()
denied = [item for item in ready["blockers"] if item["row_id"] == other_ids[0]
          and item["code"] == "not_permitted"]
check(status == 200 and len(denied) == 1 and denied[0]["field"] == "calculation"
      and "private" not in json.dumps(ready) and ready["can_calculate"] is False,
      "S3-READY-9 a per-row caller-authority refusal is fail-closed, targeted and discloses no database text")
CALCULATE_INPUTS_ROW_ERRORS.clear()
ROWS["batch_calculations"][0].update(calculation_fingerprint="calc-fp-current",
                                     presentation_fingerprint="present-fp-current")

route_statuses = [route["status"] for route in ROWS["delivery_groups"]]
for route in ROWS["delivery_groups"]:
    if route["pricing_group_id"] == 81:
        route["status"] = "removed"
status, ready = readiness()
route_blockers = [item for item in ready["blockers"] if item["code"] == "delivery_group_absent"
                  and item["pricing_group_id"] == 81]
check(status == 200 and len(route_blockers) == 1
      and route_blockers[0]["scope"] == "group" and route_blockers[0]["pricing_group_id"] == 81
      and route_blockers[0]["row_id"] is None and route_blockers[0]["field"] == "delivery_route",
      "S3-READY-10 one missing route blocker opens the exact Pricing Group instead of duplicating per row")
for route, route_status in zip(ROWS["delivery_groups"], route_statuses):
    route["status"] = route_status

rpc_before_invalid = len(RPC_CALLS)
with app.test_client() as client:
    response = client.post("/batches/71/profile", headers=AUTH, json={
        "expected_content_version": ROWS["batches"][0]["content_version"],
        "conv_box_rate": -1, "waste_cbb_pct": None,
    })
check(response.status_code == 400 and len(RPC_CALLS) == rpc_before_invalid,
      "U4-PROFILE-1 negative profile input is refused before the governed RPC")

profile_expected = ROWS["batches"][0]["content_version"]
with app.test_client() as client:
    response = client.post("/batches/71/profile", headers=AUTH, json={
        "expected_content_version": profile_expected,
        "conv_box_rate": 0, "waste_cbb_pct": None, "margin_box_pct": 8,
        "conv_pp_rate": 12.5, "waste_pp_pct": 0, "margin_pp_pct": None,
    })
profile_workspace = response.get_json()["batch"]
check(response.status_code == 200
      and RPC_CALLS[-1][1] == "revise_batch_profile"
      and RPC_CALLS[-1][2]["p_expected_content_version"] == profile_expected,
      "U4-PROFILE-2 profile revision uses the governed CAS RPC with the caller token")
check(profile_workspace["current_profile"]["version_no"] == 4
      and profile_workspace["current_profile"]["conv_box_rate"] == 0
      and profile_workspace["current_profile"]["waste_cbb_pct"] is None,
      "U4-PROFILE-3 read-back preserves explicit zero, blank and immutable version progression")

with app.test_client() as client:
    response = client.post("/batches/71/sets", headers=AUTH,
                           json={"box_row_id": 351, "set_code": "SET-01"})
set_workspace = response.get_json()["batch"]
set_item = set_workspace["batch_sets"][0]
check(response.status_code == 201 and set_item["status"] == "dissolved"
      and set_item["active_component_count"] == 0,
      "U4-SET-1 starting a SET writes only identity and reads database-derived dissolved state")

with app.test_client() as client:
    response = client.post(f"/batches/71/sets/{set_item['id']}/memberships", headers=AUTH,
                           json={"row_id": created_row["id"], "role": "plate"})
active_set = response.get_json()["batch"]["batch_sets"][0]
membership = active_set["memberships"][0]
check(response.status_code == 201 and active_set["status"] == "active"
      and active_set["active_component_count"] == 1
      and membership["row_id"] == created_row["id"],
      "U4-SET-2 first non-Box membership activates and recounts the SET through database state")

with app.test_client() as client:
    response = client.patch(f"/batches/71/set-memberships/{membership['id']}", headers=AUTH,
                            json={"status": "removed", "role": "plate"})
dissolved_set = response.get_json()["batch"]["batch_sets"][0]
check(response.status_code == 200 and dissolved_set["status"] == "dissolved"
      and dissolved_set["active_component_count"] == 0
      and dissolved_set["memberships"][0]["status"] == "removed",
      "U4-SET-3 removal preserves membership history and database-derived dissolved state")

writes_before_invalid = len(TABLE_WRITES)
with app.test_client() as client:
    response = client.post(f"/batches/71/sets/{set_item['id']}/memberships", headers=AUTH,
                           json={"row_id": 351, "role": "plate"})
check(response.status_code == 400 and len(TABLE_WRITES) == writes_before_invalid,
      "U4-SET-4 a Box cannot be attached as its own component")

DENIED_TABLES.add("batch_set_memberships")
with app.test_client() as client:
    response = client.patch(f"/batches/71/set-memberships/{membership['id']}", headers=AUTH,
                            json={"status": "active", "role": "plate"})
check(response.status_code == 403 and response.get_json()["error_code"] == "CAPABILITY_REQUIRED",
      "U4-SET-5 RLS denial cannot be presented as a successful SET change")
DENIED_TABLES.clear()
check(all(write[0] == "tok-u4" for write in TABLE_WRITES),
      "U4-SET-6 every SET and membership write carries the genuine caller token")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U4 Batch Pricing Basis route gate PASS")
