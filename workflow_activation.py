"""Pure, conservative workflow activation signals for caller-visible records."""


def _state(enabled, reason):
    return {"enabled": bool(enabled), "reason": "available" if enabled else reason}


def _plant_caps(caller, plant_code):
    return set(((caller or {}).get("plant_capabilities") or {}).get(plant_code, []))


def quote_revision_actions(caller, batch, revision, is_collaborator=False):
    """Describe only HTTP operations that are actually mounted by the backend.

    The database RPC remains the final authority. This signal deliberately
    under-enables if participant evidence is unavailable; it never guesses a
    caller is an owner or collaborator.
    """
    plant_code = ((batch or {}).get("plant") or {}).get("plant_code")
    caps = _plant_caps(caller, plant_code)
    participant = bool(batch) and (
        (caller or {}).get("id") == batch.get("owner_user_id") or is_collaborator
    )
    maker = "make_quote" in caps and participant
    checker = "check_quote" in caps
    admin = "administer_users" in (caller or {}).get("group_capabilities", [])
    revision_status = (revision or {}).get("workflow_status")
    batch_status = (batch or {}).get("status")
    standing = (revision or {}).get("standing")
    unavailable = "not_available_for_current_state_or_authority"

    return {
        "calculate": _state(False, "use_source_batch_workspace"),
        "send": _state(False, "use_source_batch_workspace"),
        "submit": _state(maker and revision_status == "draft" and batch_status == "sent", unavailable),
        "approve": _state(checker and revision_status == "submitted" and batch_status == "submitted", unavailable),
        "return": _state(checker and revision_status == "submitted" and batch_status == "submitted", unavailable),
        "withdraw": _state((checker or maker) and revision_status == "approved" and batch_status == "approved", unavailable),
        "share": _state(maker and revision_status == "approved" and batch_status == "approved"
                        and standing not in ("superseded", "voided"), unavailable),
        "create_revision": _state(
            maker and revision_status == "issued" and standing in ("current", "voided")
            and batch_status == "issued_locked", unavailable),
        "record_outcome": _state(
            (maker or checker or admin) and revision_status == "issued", unavailable),
        "amend": _state(False, "not_available_in_limited_beta"),
        "reprice": _state(False, "not_available_in_limited_beta"),
    }


def batch_actions(caller, batch):
    """State signal for Batch catalogue/workspace operations that have routes."""
    plant_code = ((batch or {}).get("plant") or {}).get("plant_code")
    caps = _plant_caps(caller, plant_code)
    participant = bool(batch) and (caller or {}).get("id") == batch.get("owner_user_id")
    maker = "make_quote" in caps and participant
    status = (batch or {}).get("status")
    available = "not_available_for_current_state_or_authority"
    return {
        "calculate": _state(maker and status in ("working", "sent"), available),
        "send": _state(maker and status in ("working", "sent"), available),
        "submit": _state(False, "open_quote_candidate"),
        "approve": _state(False, "open_quote_candidate"),
        "return": _state(False, "open_quote_candidate"),
        "share": _state(False, "open_quote_candidate"),
    }
