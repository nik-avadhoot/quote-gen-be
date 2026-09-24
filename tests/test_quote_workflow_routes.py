"""Wave D caller-bound HTTP routes for the existing S9(c) workflow RPCs."""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES, CALLS = 0, [], []
CALLER = None
RPC_DATA = None
RPC_ERROR = None


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-workflow", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def rpc(self, name, params):
        CALLS.append((self.token, name, params))

        class Response:
            def execute(_self):
                if RPC_ERROR is not None:
                    raise RPC_ERROR
                return type("RpcResponse", (), {"data": RPC_DATA})()

        return Response()


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
    AssertionError("Quote workflow routes must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-workflow"}

with app.test_client() as client:
    response = client.post("/quotes/revisions/601/approve")
check(response.status_code == 401, "WD-HTTP-1 anonymous workflow mutation is refused")

CALLER = {"id": 4, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": []}
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/submit",
                           json={"expected_content_version": True}, headers=AUTH)
check(response.status_code == 400, "WD-HTTP-2 Submit requires an exact positive CAS token")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/submit",
                           json={"expected_content_version": 7}, headers=AUTH)
check(response.status_code == 200
      and ("tok-workflow", "submit_quote_revision",
           {"p_revision": 601, "p_expected_content_version": 7}) in CALLS,
      "WD-HTTP-3 Submit forwards the caller token and exact RPC arguments")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/return",
                           json={"note": "  clarify delivery  "}, headers=AUTH)
check(response.status_code == 200
      and CALLS[-1][1:] == ("return_quote_revision",
                            {"p_revision": 601, "p_note": "clarify delivery"}),
      "WD-HTTP-4 Return forwards a required trimmed note")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/approve", headers=AUTH)
check(response.status_code == 200 and CALLS[-1][1] == "approve_quote_revision",
      "WD-HTTP-5 Approve is mounted on the existing governed RPC")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/withdraw",
                           json={"reason": "commercial correction"}, headers=AUTH)
check(response.status_code == 200 and CALLS[-1][1] == "withdraw_quote_revision",
      "WD-HTTP-6 Withdraw carries its governed reason")

CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/share", json={
        "channel": "Email", "shared_on": "2026-09-17", "external_reference": "MAIL-22"}, headers=AUTH)
check(response.status_code == 200 and CALLS[-1][1] == "share_quote_revision"
      and CALLS[-1][2] == {"p_revision": 601, "p_channel": "Email",
                            "p_shared_on": "2026-09-17", "p_external_reference": "MAIL-22"},
      "WD-HTTP-7 Share forwards only manual evidence; recipient and actor stay server-derived")

with app.test_client() as client:
    response = client.post("/quotes/revisions/601/share", json={
        "channel": "Guessed recipient", "shared_on": "2026-09-17"}, headers=AUTH)
check(response.status_code == 400 and not any(call[1] == "share_quote_revision" and call[2].get("p_channel") == "Guessed recipient" for call in CALLS),
      "WD-HTTP-7a an unsupported channel is refused before any database write")

RPC_DATA = 602
CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/601/create-revision", headers=AUTH)
check(response.status_code == 201 and response.get_json()["id"] == 602
      and CALLS[-1][1] == "create_quote_revision",
      "WD-HTTP-8 Create Revision returns the governed identity")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Wave D Quote workflow route gate PASS")
