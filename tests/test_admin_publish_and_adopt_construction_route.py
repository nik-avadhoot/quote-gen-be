"""/masters/constructions/publish-and-adopt input-validation contract.

This route's success path calls a live Supabase RPC
(admin_publish_and_adopt_construction, S4-7 migration), which this test suite
cannot reach from a sandboxed environment with no Supabase credentials or CLI
access - there is no local/offline equivalent of a PostgREST RPC call the way
there is for the openpyxl-driven /export route. This suite instead proves
every INVALID_INPUT refusal fires before any network call is made, so a caller
sending malformed input never reaches the RPC (and never reaches
`get_supabase_for_caller`, which would raise for lack of real credentials in
this environment - its absence from these tracebacks IS part of what each
`check` below establishes).

Live coverage owed once Supabase access exists: a genuine caller holding both
manage_construction_library and adopt_construction_for_plant succeeds end to
end with a real construction_code allocated (RM-6-style parity check against
CBB+PP export naming was NOT needed here - Constructions don't touch the xlsx
template); a caller missing either capability is refused CAPABILITY_REQUIRED
by the RPC itself before any row is written (S4-7's up-front check, verified
only by reading the migration's SQL in this session, not by executing it).
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import server  # noqa: E402

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def post(body):
    with server.app.test_request_context(
            "/masters/constructions/publish-and-adopt", method="POST", json=body):
        # require_auth needs a caller; this suite only exercises the
        # validation refusals that fire BEFORE that resolution matters, so a
        # minimal g.caller stand-in is enough - none of these paths read it.
        server.g.caller = {"id": 1, "plant_capabilities": {}}
        server.g.access_token = "test-token-not-used"
        return server.admin_publish_and_adopt_construction_route.__wrapped__()


def refused(body, label):
    resp = post(body)
    body_json, status = resp[0].get_json(), resp[1]
    check(status == 400 and body_json.get("error_code") == "INVALID_INPUT", label)


refused({}, "PA-1 missing plant_id is refused before any RPC call")
refused({"plant_id": 1}, "PA-2 missing name is refused")
refused({"plant_id": 1, "name": "Test Box"}, "PA-3 missing ply is refused")
refused({"plant_id": 1, "name": "Test Box", "ply": 0}, "PA-4 ply outside 1..11 is refused (0)")
refused({"plant_id": 1, "name": "Test Box", "ply": 12}, "PA-5 ply outside 1..11 is refused (12)")
refused({"plant_id": 1, "name": "  ", "ply": 5},
        "PA-6 a whitespace-only name is refused, not silently trimmed to empty")
refused({"plant_id": 1, "name": "Test Box", "ply": 5, "board_gsm": -1},
        "PA-7 a negative board_gsm is refused")
refused({"plant_id": 1, "name": "Test Box", "ply": 5, "flute_f1": 7},
        "PA-8 a non-string flute_f1 is refused")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("admin_publish_and_adopt_construction input-validation contract PASS")
