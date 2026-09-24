"""Governed Calculate and Atomic Send caller-bound route gate."""
import os
import sys
import json

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []
CALLER = None
CALLS = []
RPC_OUTCOME = {"data": 8801}
EXECUTOR_OUTCOME = {"status": 200, "batch_calculation_id": 7701, "error_code": None}


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table
        self.filters = []

    def select(self, _columns):
        return self

    def eq(self, column, value):
        self.filters.append((column, value))
        return self

    def limit(self, _maximum):
        return self

    def execute(self):
        CALLS.append(("table", self.token, self.table, tuple(self.filters)))
        rows = [{"id": 91, "batch_id": 71, "status": "active", "content_version": 3}]
        for column, value in self.filters:
            rows = [row for row in rows if str(row.get(column)) == str(value)]
        return type("Response", (), {"data": rows})()


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-calc", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)

    def rpc(self, name, params):
        CALLS.append(("rpc", self.token, name, params))

        class Response:
            def execute(_self):
                if isinstance(RPC_OUTCOME, Exception):
                    raise RPC_OUTCOME
                return type("RpcResponse", (), RPC_OUTCOME)()

        return Response()


def fake_client(token):
    return FakeClient(token)


TRANSPORT = {}


class FakeExecutorResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _maximum):
        return b'{"batch_calculation_id":7701}'


def fake_urlopen(req, timeout):
    TRANSPORT.update({"url": req.full_url, "headers": dict(req.header_items()),
                      "body": json.loads(req.data), "timeout": timeout})
    return FakeExecutorResponse()


original_urlopen = cc.urllib.request.urlopen
cc.urllib.request.urlopen = fake_urlopen
transport_result = cc.invoke_calculation_executor("tok-calc", 91)
cc.urllib.request.urlopen = original_urlopen
check(transport_result["batch_calculation_id"] == 7701
      and TRANSPORT["url"] == "https://test.invalid/functions/v1/calculate-batch-row"
      and TRANSPORT["headers"].get("Authorization") == "Bearer tok-calc"
      and TRANSPORT["headers"].get("Apikey") == "test-publishable-key-not-real"
      and "test-secret-key-not-real" not in TRANSPORT["headers"].values()
      and TRANSPORT["body"] == {"batch_row_id": 91},
      "U5-CS-BE-0 trusted execution forwards the caller JWT plus publishable key, never service role")


cc.get_supabase_for_caller = fake_client
cc.new_caller_client = fake_client
import server  # noqa: E402
import auth as auth_mod  # noqa: E402

server.get_supabase_for_caller = fake_client
server.new_caller_client = fake_client
auth_mod.get_supabase_for_caller = fake_client
auth_mod.resolve_caller = lambda _token, known_auth_uid=None: CALLER
server.invoke_calculation_executor = lambda token, row_id: (
    CALLS.append(("executor", token, row_id)) or EXECUTOR_OUTCOME)
server.privileged_client = lambda _operation: (_ for _ in ()).throw(
    AssertionError("Calculate and Send must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-calc"}

with app.test_client() as client:
    response = client.post("/batches/71/rows/91/calculate")
check(response.status_code == 401, "U5-CS-BE-1 anonymous Calculate is refused")

CALLER = {"id": 4, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": []}
CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches/72/rows/91/calculate", headers=AUTH)
check(response.status_code == 404 and not any(call[0] == "executor" for call in CALLS),
      "U5-CS-BE-2 the path Batch must own the row before trusted execution")

CALLS.clear()
EXECUTOR_OUTCOME = {"status": 200, "batch_calculation_id": "7701", "error_code": None}
with app.test_client() as client:
    response = client.post("/batches/71/rows/91/calculate", headers=AUTH)
payload = response.get_json()
check(response.status_code == 200 and payload["batch_calculation_id"] == 7701
      and payload["authority"] == "caller_token_trusted_executor_database_writer",
      "U5-CS-BE-3 Calculate returns only the admitted database identity")
check(("executor", "tok-calc", 91) in CALLS
      and all(call[1] == "tok-calc" for call in CALLS),
      "U5-CS-BE-4 row membership and trusted execution carry the genuine caller token")

EXECUTOR_OUTCOME = {"status": 503, "error_code": "EXECUTOR_NOT_PROVISIONED"}
with app.test_client() as client:
    response = client.post("/batches/71/rows/91/calculate", headers=AUTH)
check(response.status_code == 503
      and response.get_json()["error_code"] == "CALCULATION_EXECUTOR_UNAVAILABLE",
      "U5-CS-BE-5 an unprovisioned executor is a stable unavailable result")

EXECUTOR_OUTCOME = {"status": 422, "error_code": "PT422", "error": "raw database detail"}
with app.test_client() as client:
    response = client.post("/batches/71/rows/91/calculate", headers=AUTH)
check(response.status_code == 422
      and response.get_json()["error_code"] == "CALCULATION_NOT_READY"
      and "raw database detail" not in response.get_data(as_text=True),
      "U5-CS-BE-6 Calculate refuses ineligible state without leaking database text")

with app.test_client() as client:
    response = client.post("/batches/71/send", json={"expected_content_version": True}, headers=AUTH)
check(response.status_code == 400,
      "U5-CS-BE-7 Atomic Send requires an exact positive content version")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches/71/send", json={
        "expected_content_version": 9, "customer_party_id": 999999}, headers=AUTH)
check(response.status_code == 400 and not any(call[0] == "rpc" for call in CALLS),
      "U5-CS-BE-7a a guessed Party identity is refused before Atomic Send")

RPC_OUTCOME = {"data": 8801}
CALLS.clear()
with app.test_client() as client:
    response = client.post("/batches/71/send", json={"expected_content_version": 9}, headers=AUTH)
payload = response.get_json()
check(response.status_code == 201 and payload["revision_id"] == 8801
      and payload["quote_candidate_status"] == "draft",
      "U5-CS-BE-8 Atomic Send returns the immutable draft candidate identity")
check(("rpc", "tok-calc", "send_batch",
       {"p_batch": 71, "p_expected_content_version": 9}) in CALLS,
      "U5-CS-BE-9 Atomic Send lets the database resolve only the Batch-selected recipient as the caller")

RPC_OUTCOME = server.APIError({"code": "PT422", "message": "calculation_stale",
                               "details": None, "hint": None})
with app.test_client() as client:
    response = client.post("/batches/71/send", json={"expected_content_version": 9}, headers=AUTH)
check(response.status_code == 422 and response.get_json()["error_code"] == "SEND_NOT_READY"
      and "calculation_stale" not in response.get_data(as_text=True),
      "U5-CS-BE-10 Atomic Send preserves database readiness refusal without leaking detail")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U5 governed Calculate and Atomic Send route gate PASS")
