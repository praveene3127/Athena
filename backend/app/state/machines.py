"""
Athena Canonical State Machine Validators.
Driven directly by contracts/state-machines.json.
Enforces non-negotiable architectural lifecycle invariants across all runtimes.
"""

import json
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger("athena.state_machine")

# Locate canonical contract file
_CONTRACTS_DIR = Path(__file__).resolve().parent.parent.parent.parent / "contracts"
_STATE_MACHINES_FILE = _CONTRACTS_DIR / "state-machines.json"

_CACHED_MACHINES: Dict[str, Any] = {}


def _load_machines() -> Dict[str, Any]:
    global _CACHED_MACHINES
    if _CACHED_MACHINES:
        return _CACHED_MACHINES

    if _STATE_MACHINES_FILE.exists():
        try:
            data = json.loads(_STATE_MACHINES_FILE.read_text(encoding="utf-8"))
            _CACHED_MACHINES = data.get("machines", {})
            return _CACHED_MACHINES
        except Exception as e:
            logger.warning("Could not read %s: %s. Using embedded state machines.", _STATE_MACHINES_FILE, e)

    # Embedded fallback for production or standalone packages
    _CACHED_MACHINES = {
        "DocumentLifecycle": {
            "initial": "queued",
            "states": [
                "queued", "processing", "partially_readable", "paused",
                "interrupted", "ready", "failed", "unsupported", "deleted"
            ],
            "transitions": {
                "queued": ["processing", "failed", "deleted"],
                "processing": ["partially_readable", "ready", "paused", "interrupted", "failed", "unsupported", "deleted"],
                "partially_readable": ["ready", "paused", "interrupted", "failed", "deleted"],
                "paused": ["processing", "deleted"],
                "interrupted": ["processing", "deleted"],
                "ready": ["deleted"],
                "failed": ["queued", "processing", "deleted"],
                "unsupported": ["deleted"],
                "deleted": []
            },
            "forbidden_transitions": [
                {"from": "ready", "to": "processing", "reason": "Once ready, enrichment must never regress status to processing"},
                {"from": "ready", "to": "queued", "reason": "Ready documents cannot be requeued without explicit reset"}
            ]
        },
        "CardUserState": {
            "initial": "unseen",
            "states": ["unseen", "viewed", "saved", "dismissed"],
            "transitions": {
                "unseen": ["viewed", "saved", "dismissed"],
                "viewed": ["saved", "dismissed"],
                "saved": ["viewed", "dismissed"],
                "dismissed": ["viewed", "saved"]
            }
        },
        "CardSlotSynthesis": {
            "initial": "absent",
            "states": ["absent", "in_flight", "ready", "failed_cooldown"],
            "transitions": {
                "absent": ["in_flight"],
                "in_flight": ["ready", "failed_cooldown"],
                "ready": ["absent"],
                "failed_cooldown": ["in_flight", "absent"]
            }
        }
    }
    return _CACHED_MACHINES


def get_state_machine(machine_name: str) -> Optional[Dict[str, Any]]:
    """Returns the state machine definition for machine_name."""
    machines = _load_machines()
    return machines.get(machine_name)


def can_transition(machine_name: str, from_state: str, to_state: str) -> bool:
    """
    Checks whether a state transition from from_state to to_state is valid
    according to contracts/state-machines.json.
    """
    if from_state == to_state:
        return True

    machine = get_state_machine(machine_name)
    if not machine:
        logger.warning("sm=%s Unknown state machine", machine_name)
        return False

    # Check forbidden transitions explicitly
    for forbidden in machine.get("forbidden_transitions", []):
        if forbidden.get("from") == from_state and forbidden.get("to") == to_state:
            return False

    transitions = machine.get("transitions", {})
    allowed = transitions.get(from_state, [])
    return to_state in allowed


def apply_transition(
    machine_name: str,
    entity_id: str,
    from_state: str,
    to_state: str,
    reason: str = "",
) -> str:
    """
    Validates and applies a state machine transition.
    If valid, logs structured sm=<machine> id=<id> from=<from> to=<to> telemetry and returns to_state.
    If invalid or forbidden, logs warning telemetry and returns from_state (preventing state regression).
    """
    if from_state == to_state:
        return to_state

    if can_transition(machine_name, from_state, to_state):
        logger.info(
            "sm=%s id=%s from=%s to=%s%s",
            machine_name,
            entity_id,
            from_state,
            to_state,
            f" reason='{reason}'" if reason else "",
        )
        return to_state

    logger.warning(
        "sm=%s id=%s from=%s to=%s REJECTED: forbidden or invalid transition%s",
        machine_name,
        entity_id,
        from_state,
        to_state,
        f" reason='{reason}'" if reason else "",
    )
    return from_state
