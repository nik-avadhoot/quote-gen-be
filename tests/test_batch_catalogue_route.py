"""U4 caller-scoped, bounded My Batches catalogue gate."""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []
CALLER, DENIED, CALLS = None, set(), []


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
        "id": 72, "batch_reference": "NAG/BAT/2026-27/00072", "family_id": 22,
        "plant_id": 7, "owner_user_id": 4, "sector_id": 32, "status": "submitted",
        "content_version": 6, "pricing_date": "2026-09-13", "pricing_basis_release_id": 12,
        "pricing_basis_is_deliberate": True, "created_at": "2026-09-13T08:30:00Z", "created_by": 4,
    }, {
        "id": 71, "batch_reference": "PUN/BAT/2026-27/00071", "family_id": 21,
        "plant_id": 8, "owner_user_id": 4, "sector_id": 31, "status": "working",
        "content_version": 3, "pricing_date": "2026-09-12", "pricing_basis_release_id": 11,
        "pricing_basis_is_deliberate": False, "created_at": "2026-09-12T07:15:00Z", "created_by": 4,
    }],
    "customer_families": [
        {"id": 21, "group_customer_code": "FAM-021", "name": "Foods Family", "status": "active"},
        {"id": 22, "group_customer_code": "FAM-022", "name": "Retail Family", "status": "active"},
    ],
    "plants": [
        {"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
        {"id": 8, "plant_code": "PUN", "name": "Pune", "status": "active"},
    ],
    "sectors": [
        {"id": 31, "sector_code": "FOOD", "name": "Food", "status": "active"},
        {"id": 32, "sector_code": "FMCG", "name": "FMCG", "status": "active"},
    ],
    "pricing_basis_releases": [
        {"id": 11, "plant_id": 8, "release_name": "PUN September", "status": "approved",
         "effective_from": "2026-09-01", "effective_until": None, "is_automatic_default": True},
        {"id": 12, "plant_id": 7, "release_name": "NAG September", "status": "approved",
         "effective_from": "2026-09-01", "effective_until": "2026-09-30", "is_automatic_default": False},
    ],
    "app_users": [{"id": 4, "display_name": "Maker", "status": "active"}],
}


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table
        self.columns, self.filters, self.in_filters = "*", [], []
        self.maximum, self.ordering = None, None

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

    def limit(self, maximum):
        self.maximum = maximum
        return self

    def order(self, column, desc=False):
        self.ordering = (column, desc)
        return self

    def execute(self):
        if self.table in DENIED:
            raise server.APIError({"code": "42501", "message": "denied", "details": None, "hint": None})
        CALLS.append((self.token, self.table, tuple(self.filters), tuple(self.in_filters)))
        rows = list(ROWS.get(self.table, []))
        for column, value in self.filters:
            if column.endswith("__lt"):
                rows = [row for row in rows if row.get(column[:-4], 0) < value]
            else:
                rows = [row for row in rows if str(row.get(column)) == str(value)]
        for column, values in self.in_filters:
            rows = [row for row in rows if row.get(column) in values]
        if self.ordering:
            column, descending = self.ordering
            rows.sort(key=lambda row: row.get(column) or "", reverse=descending)
        if self.maximum is not None:
            rows = rows[:self.maximum]
        wanted = [field.strip() for field in self.columns.split(",")]
        return type("Response", (), {"data": [
            {field: row.get(field) for field in wanted} for row in rows
        ]})()


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-u4-catalogue", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)


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
    AssertionError("My Batches must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-u4-catalogue"}

with app.test_client() as client:
    response = client.get("/batches/catalogue")
check(response.status_code == 401, "U4-CAT-BE-1 anonymous Batch catalogue access is refused")

CALLER = {"id": 4, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "make_quote"], "PUN": ["plant_access", "make_quote"]},
          "group_capabilities": []}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
payload = response.get_json()
catalogue = payload["catalogue"]
check(response.status_code == 200 and payload["authority"] == "caller_token_rls_only",
      "U4-CAT-BE-2 catalogue is a caller-token/RLS-only read surface")
check([row["id"] for row in catalogue["rows"]] == [72, 71],
      "U4-CAT-BE-3 caller-visible Batches are newest-first")
first = catalogue["rows"][0]
check(first["batch_reference"] == "NAG/BAT/2026-27/00072"
      and first["customer_family"]["group_customer_code"] == "FAM-022"
      and first["plant"]["plant_code"] == "NAG"
      and first["sector"]["sector_code"] == "FMCG",
      "U4-CAT-BE-4 exact Batch, Family, Plant and selected Sector identities are retained")
check(first["pricing_basis_release_id"] == 12
      and first["pricing_basis_release"]["release_name"] == "NAG September"
      and first["pricing_basis_is_deliberate"] is True
      and first["pricing_date"] == "2026-09-13",
      "U4-CAT-BE-5 exact persisted Pricing Basis identity, mode and date are retained")
check(first["status"] == "submitted" and first["owner"]["display_name"] == "Maker",
      "U4-CAT-BE-6 Batch status and caller-visible owner identity stay explicit")
check(catalogue["display_limit"] == 50 and catalogue["results_limited"] is False
      and catalogue["filter_scope"] == "displayed_newest_first_window",
      "U4-CAT-BE-7 the bounded operational display contract is explicit")
check(catalogue["actions"]["calculate"]["enabled"]
      and catalogue["actions"]["send"]["enabled"]
      and not catalogue["actions"]["submit"]["enabled"],
      "U4-CAT-BE-8 mounted Batch actions activate while Quote actions require a candidate")
check(CALLS and all(call[0] == "tok-u4-catalogue" for call in CALLS),
      "U4-CAT-BE-9 every primary and supporting read carries the genuine caller token")

DENIED.add("sectors")
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
partial = response.get_json()["catalogue"]
check(response.status_code == 200 and partial["details_partial"] is True
      and "sectors" in partial["denied_sections"] and partial["rows"][0]["sector"] is None,
      "U4-CAT-BE-10 denied supporting detail is explicit and no Sector identity is invented")
DENIED.clear()

original_batches = ROWS["batches"]
ROWS["batches"] = [{**original_batches[0], "id": index,
                     "batch_reference": f"NAG/BAT/2026-27/{index:05d}",
                     "created_at": f"2026-09-13T{index % 24:02d}:00:{index:02d}Z"}
                    for index in range(1, 52)]
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
bounded = response.get_json()["catalogue"]
check(response.status_code == 200 and len(bounded["rows"]) == 50 and bounded["results_limited"] is True,
      "U4-CAT-BE-11 a 51st visible Batch proves the 50-row catalogue is incomplete")
check(bounded["next_cursor"] == 2 and bounded["scope"] == "open",
      "ACTIVE-1 the open-work page exposes an older-work cursor")
with app.test_client() as client:
    response = client.get("/batches/catalogue?before_id=2", headers=AUTH)
check(response.status_code == 200 and [row["id"] for row in response.get_json()["catalogue"]["rows"]] == [1],
      "ACTIVE-2 an older open Batch is reachable through server-side pagination")
ROWS["batches"] = original_batches

ROWS["batches"] = original_batches + [
    {**original_batches[0], "id": 100, "status": "issued_locked"},
    {**original_batches[0], "id": 101, "status": "abandoned"},
    {**original_batches[0], "id": 102, "status": "archived"},
    {**original_batches[0], "id": 103, "status": "approved"},
]
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
check(response.status_code == 200 and [row["id"] for row in response.get_json()["catalogue"]["rows"]] == [103, 72, 71],
      "ACTIVE-3 active work includes approved-awaiting-issue but excludes terminal records before limit")
with app.test_client() as client:
    response = client.get("/batches/catalogue?scope=closed", headers=AUTH)
check(response.status_code == 200 and [row["id"] for row in response.get_json()["catalogue"]["rows"]] == [102, 101, 100],
      "ACTIVE-4 issued, abandoned and archived Batches are separate from active work")
ROWS["batches"] = original_batches

ROWS["batches"] = []
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
empty = response.get_json()["catalogue"]
check(response.status_code == 200 and empty["rows"] == []
      and empty["details_partial"] is False and empty["results_limited"] is False,
      "U4-CAT-BE-12 a genuine caller-visible empty catalogue remains a successful empty result")
ROWS["batches"] = original_batches

DENIED.add("batches")
with app.test_client() as client:
    response = client.get("/batches/catalogue", headers=AUTH)
check(response.status_code == 403,
      "U4-CAT-BE-13 a table-level Batch denial is distinct from an empty catalogue")
DENIED.clear()

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U4 My Batches catalogue route gate PASS")
