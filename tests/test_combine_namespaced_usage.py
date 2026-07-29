"""High-fidelity unit tests for the multi-home namespace fail-closed contract.

``_combine_and_limit_namespaced_usage`` is the boundary that joins usage events
collected from several client *homes* (distinct source namespaces). A client
session id is authoritative only inside its own home namespace, so when the same
id appears in two homes — or a parent reference points at a session that lives
only in another home — the affected lineage is excluded fail-closed and surfaced
through stable diagnostics, rather than silently joined into a wrong attribution.

These tests exercise the private selector directly with constructed events so
every branch of the safety contract is reachable and pinned. Direct private-call
testing follows the precedent in ``test_client_usage.py`` (e.g.
``client_usage_module._merge_multi_home_discovery_stats``).
"""

from __future__ import annotations

from pathlib import Path

import agent_chronicle.client_usage as client_usage_module
from agent_chronicle.client_usage import ClientUsageEvent

HOME_A = "sha256:" + "a" * 64
HOME_B = "sha256:" + "b" * 64


def _ev(
    session_id: str,
    *,
    parent: str | None = None,
    kind: str = "root",
    updated_at: int = 1000,
    model: str = "claude-test",
) -> ClientUsageEvent:
    """Minimal realistic usage event for combine/limit scenarios.

    ``client_session_kind`` and ``updated_at`` drive root-resolution and
    activity ordering; ``model`` disambiguates events that share a session id
    across homes.
    """
    return ClientUsageEvent(
        client="claude-code",
        client_session_id=session_id,
        source_path=Path(f"/fake/{session_id}.jsonl"),
        title=None,
        cwd="/repo",
        model=model,
        input_tokens=1,
        output_tokens=1,
        client_session_kind=kind,
        parent_client_session_id=parent,
        updated_at=updated_at,
    )


def _combine(batches, *, limit_root_groups=10):
    return client_usage_module._combine_and_limit_namespaced_usage(
        batches, limit_root_groups=limit_root_groups
    )


# ---------------------------------------------------------------------------
# Early-return contract
# ---------------------------------------------------------------------------


def test_zero_limit_returns_empty_without_selecting_anything():
    selected, roots, codes, invalid, by_limit, by_ns = _combine(
        [(HOME_A, [_ev("s1")])], limit_root_groups=0
    )
    assert selected == []
    assert roots == 0
    assert codes == []
    assert invalid == 0
    assert by_limit == 0
    assert by_ns == 0


def test_empty_home_batches_return_empty():
    selected, roots, codes, invalid, by_limit, by_ns = _combine([], limit_root_groups=10)
    assert selected == []
    assert roots == 0
    assert codes == []
    assert invalid == 0
    assert by_limit == 0
    assert by_ns == 0


# ---------------------------------------------------------------------------
# Happy path: a single clean home selects its session
# ---------------------------------------------------------------------------


def test_single_home_clean_session_is_selected():
    event = _ev("solo", updated_at=5000)
    selected, roots, codes, invalid, by_limit, by_ns = _combine(
        [(HOME_A, [event])], limit_root_groups=10
    )
    assert [e.client_session_id for e in selected] == ["solo"]
    assert roots == 1
    assert codes == []
    assert invalid == 0
    assert by_limit == 0
    assert by_ns == 0


# ---------------------------------------------------------------------------
# Fail-closed contract: collisions and cross-home parents are excluded
# ---------------------------------------------------------------------------


def test_same_session_id_in_two_homes_is_excluded_fail_closed():
    """A client session id is authoritative only inside one home namespace.

    If the same id surfaces in two homes, neither copy can be trusted to be the
    'real' one, so both are dropped and the collision is reported — never
    silently merged.
    """
    home_a_event = _ev("shared", model="model-a", updated_at=100)
    home_b_event = _ev("shared", model="model-b", updated_at=200)

    selected, roots, codes, invalid, by_limit, by_ns = _combine(
        [(HOME_A, [home_a_event]), (HOME_B, [home_b_event])],
        limit_root_groups=10,
    )

    assert selected == []
    assert roots == 0
    assert codes == ["source_namespace_session_collision"]
    assert by_ns == 2  # one excluded identity per (namespace, session) copy
    assert by_limit == 0


def test_child_whose_parent_lives_in_another_home_is_excluded():
    """A parent reference that crosses into a different namespace is ambiguous.

    The child cannot be safely attached to a bare id from another home, so it is
    excluded fail-closed; the parent keeps standing as a valid root in its own
    home.
    """
    parent_in_b = _ev("parent", model="model-b", updated_at=300)
    child_in_a = _ev("child", parent="parent", kind="child", updated_at=100)

    selected, roots, codes, invalid, by_limit, by_ns = _combine(
        [(HOME_A, [child_in_a]), (HOME_B, [parent_in_b])],
        limit_root_groups=10,
    )

    assert [e.client_session_id for e in selected] == ["parent"]
    assert [e.model for e in selected] == ["model-b"]
    assert roots == 1
    assert codes == ["source_namespace_parent_mismatch"]
    assert by_ns == 1  # only the cross-home child is excluded


def test_descendants_of_an_invalid_parent_are_excluded_too():
    """Exclusion propagates down an in-home lineage.

    A node is marked invalid here because its OWN parent lives in another home
    (a cross-home reference). Its same-home descendant — which chains through
    the invalid node — must also be excluded, otherwise a later step could
    attach the orphaned descendant to a bare id from the other home.
    Unrelated valid roots in both homes are left untouched.
    """
    # HOME_A: a clean root, an invalid mid-node, and that node's descendant.
    clean_root_a = _ev("cleanroot", model="model-a", updated_at=500)
    bad_parent = _ev("badparent", parent="foreign", kind="child", updated_at=100)
    descendant = _ev("child", parent="badparent", kind="child", updated_at=200)
    # HOME_B: the "foreign" parent that badparent points across to. It is a
    # perfectly valid root in its own home; only the cross-home reference is.
    foreign_root_b = _ev("foreign", model="model-b", updated_at=900)

    selected, roots, codes, invalid, by_limit, by_ns = _combine(
        [
            (HOME_A, [clean_root_a, bad_parent, descendant]),
            (HOME_B, [foreign_root_b]),
        ],
        limit_root_groups=10,
    )

    selected_ids = sorted(e.client_session_id for e in selected)
    assert selected_ids == ["cleanroot", "foreign"]  # badparent + child dropped
    assert roots == 2
    assert codes == ["source_namespace_parent_mismatch"]
    assert by_ns == 2  # the invalid mid-node and its propagated descendant
