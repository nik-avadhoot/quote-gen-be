"""Wave D real workflow activation signal gate."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from workflow_activation import batch_actions, quote_revision_actions  # noqa: E402

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


maker = {"id": 4, "plant_capabilities": {"NAG": ["plant_access", "make_quote"]}}
checker = {"id": 5, "plant_capabilities": {"NAG": ["plant_access", "check_quote"]}}
wrong_plant = {"id": 4, "plant_capabilities": {"PUN": ["plant_access", "make_quote"]}}
batch = {"owner_user_id": 4, "status": "sent", "plant": {"plant_code": "NAG"}}

actions = quote_revision_actions(maker, batch, {"workflow_status": "draft", "standing": None})
check(actions["submit"]["enabled"] and actions["submit"]["reason"] == "available",
      "WD-1 a real mounted Submit path activates for its eligible Maker")
check(not actions["approve"]["enabled"], "WD-2 state-ineligible approval stays disabled")
check(not quote_revision_actions(wrong_plant, batch, {"workflow_status": "draft"})["submit"]["enabled"],
      "WD-3 wrong-plant capability never activates Submit")

submitted = {**batch, "status": "submitted"}
checker_actions = quote_revision_actions(checker, submitted, {"workflow_status": "submitted"})
check(checker_actions["approve"]["enabled"] and checker_actions["return"]["enabled"],
      "WD-4 eligible Checker gets the two mounted review transitions")

approved = {**batch, "status": "approved"}
maker_actions = quote_revision_actions(maker, approved, {"workflow_status": "approved"})
check(maker_actions["share"]["enabled"] and maker_actions["withdraw"]["enabled"],
      "WD-5 owner Maker gets mounted eligible Issue and Withdraw")
check(not maker_actions["amend"]["enabled"] and not maker_actions["reprice"]["enabled"]
      and maker_actions["amend"]["reason"] == "not_available_in_limited_beta",
      "WD-6 actions without a beta route remain disabled with an exact reason")

batch_state = batch_actions(maker, {**batch, "status": "working"})
check(batch_state["calculate"]["enabled"] and batch_state["send"]["enabled"],
      "WD-7 mounted Batch Calculate and Send paths activate for an eligible owner")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Wave D workflow activation gate PASS")
