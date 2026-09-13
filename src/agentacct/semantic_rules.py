"""Display-quality and completeness rules for agent-recorded work.

One implementation for every write lane. The MCP tool handlers call these
directly so a refusal reaches the agent as a JSON-RPC error it can act on; the
shared `SentinelService.record_event` choke point calls the same functions so
the HTTP and CLI lanes cannot store a record the MCP lane would refuse.

Design and measurements: ``design-plans/data-quality/RULES.md``. The short
version of why these are refusals rather than quality markers: a record the UI
cannot render is worse than a refusal an agent can fix in one retry, and the
replay of the real ledger (1,504 records) shows zero legitimate reports refused.

Every rule below was validated in both directions -- it refuses the incomplete
record AND accepts every shape the real ledger contains -- because a rule that
is merely strict is not a rule, it is a data-loss bug.
"""

from __future__ import annotations

import unicodedata
from typing import Any

# --- text normalization -----------------------------------------------------

# Whitespace that carries display meaning and therefore survives the control
# sweep below. Tab, newline, vertical tab, form feed and carriage return are all
# category Cc, exactly like the C1 controls the sweep exists to remove -- so the
# exception has to be explicit. (Getting this wrong twice is why the fuzz suite
# asserts both directions: control characters are gone AND line structure
# survives.)
_DISPLAY_MEANINGFUL_WHITESPACE = frozenset("\t\n\v\f\r")

_DISPLAY_LINE_BREAKS = str.maketrans({"\t": " ", "\n": " ", "\r": " ", "\v": " ", "\f": " "})

# Names that carry no identity. Supersession keys on a check's name, so two
# unrelated checks sharing one of these would supersede each other.
GENERIC_CHECK_NAMES = frozenset({"check", "test", "tests", "verify", "build", "run", "lint"})

# A terminal section's outcome prose must be substantial enough to read.
MINIMUM_SUMMARY_CHARACTERS = 40
MINIMUM_BLOCKER_CHARACTERS = 20

TERMINAL_STATUSES = frozenset({"completed", "blocked", "handed_off"})


class SemanticRecordError(ValueError):
    """A record cannot be stored because the UI could not render it.

    The message is written for the agent that sent the record: it names the
    field, states what the status requires, and shows a corrected call. It never
    echoes the caller's own text back (see ``_limit_error`` in the MCP lane for
    the same rule and the incident behind it).
    """


def is_control_character(character: str) -> bool:
    """C0 and C1 controls plus DEL, by Unicode category rather than by range.

    The first version of this rule enumerated the code points it knew about and
    the fuzzer found the hole immediately: U+0080-U+009F (C1 controls) slipped
    through and reached the stored title, where a renderer shows them as nothing
    or as a replacement glyph. Asking Unicode for the category cannot miss a
    code point the way a hand-written list can -- and the cost is that the
    meaningful whitespace above must be named back in.
    """
    if character in _DISPLAY_MEANINGFUL_WHITESPACE:
        return False
    return unicodedata.category(character) == "Cc"


def strip_control_characters(value: str) -> str:
    return "".join(character for character in value if not is_control_character(character))


def collapse_display_text(value: str) -> str:
    """One line, one space between words, no control characters, no outer space.

    Whitespace is normalized on both display fields and identity fields on
    purpose: "pytest  tests/x.py" and "pytest tests/x.py" name the same check,
    so collapsing them is what keeps supersession -- which keys on the name --
    from treating one check as two.
    """
    return " ".join(strip_control_characters(value.translate(_DISPLAY_LINE_BREAKS)).split())


def collapse_narrative_text(value: str) -> str:
    """Narrative prose: keep real line structure, drop other control characters.

    Line breaks are preserved on purpose. They are how an agent separates a
    summary from the structured text it accidentally absorbed -- a mangled tool
    call arrives as ``...text.</summary>\\n<files>...</files>`` -- and the
    mangled-call detector reads exactly that structure. Collapsing the newline
    would hide the signal the detector exists to find.

    A run of blank lines collapses to one: it renders identically and only makes
    a card taller, so one blank line is the canonical stored form.
    """
    cleaned = strip_control_characters(value.replace("\r\n", "\n").replace("\r", "\n"))
    lines = [" ".join(line.replace("\t", " ").split()) for line in cleaned.split("\n")]
    collapsed: list[str] = []
    for line in lines:
        if not line and collapsed and not collapsed[-1]:
            continue
        collapsed.append(line)
    return "\n".join(collapsed).strip()


def readable_text_or_none(value: Any) -> str | None:
    """A single-line display value, or None when nothing readable was supplied."""
    if not isinstance(value, str):
        return None
    collapsed = collapse_display_text(value)
    return collapsed or None


def has_readable_title(value: Any) -> bool:
    """True when a title contains at least two letters or digits.

    `isalnum()` alone would reject readable scripts (Hangul jamo, some combining
    forms), so the check also accepts letter categories.
    """
    collapsed = readable_text_or_none(value)
    if collapsed is None:
        return False
    return (
        sum(
            1
            for character in collapsed
            if character.isalnum() or unicodedata.category(character).startswith("L")
        )
        >= 2
    )


# --- rule checks over a semantic record -------------------------------------


def require_terminal_outcome(
    status: str,
    *,
    summary: Any,
    blocker: Any,
    next_step: Any = None,
    section_id: str = "",
    source: str = "",
    title: str | None = None,
) -> None:
    """A terminal section must carry the outcome a reader came for (R4).

    A finished chapter with nothing to read is the most visible hole in the
    timeline: the canvas card shows its title plus a status word and nothing
    else. The refusal names the missing field and shows the corrected call, so a
    single retry is enough.
    """
    requirement = {
        "completed": ("summary", MINIMUM_SUMMARY_CHARACTERS, "describe what actually changed and what was verified"),
        "handed_off": ("summary", MINIMUM_SUMMARY_CHARACTERS, "say what is complete and what remains"),
        "blocked": ("blocker", MINIMUM_BLOCKER_CHARACTERS, "state the concrete blocker"),
    }.get(status)
    if requirement is None:
        return
    key, minimum, advice = requirement
    supplied = summary if key == "summary" else blocker
    text = supplied if isinstance(supplied, str) else None
    if text is not None and len(collapse_narrative_text(text)) >= minimum:
        return

    example_args = [f'source="{source}"', f'section_id="{section_id}"', f'section_status="{status}"']
    if title:
        example_args.append(f'section_title="{collapse_display_text(title)[:60]}"')
    example_args.append(
        f'{key}="<what changed, then what was verified>"'
        if key == "summary"
        else f'{key}="<the concrete blocker>"'
    )
    received = "no " + key if text is None or not text.strip() else f"{key} of {len(collapse_narrative_text(text))} characters"
    raise SemanticRecordError(
        f"section_status={status} requires `{key}` (at least {minimum} characters): {advice}. "
        f"Received: {received}. Re-send the same section_id with that field, for example: "
        f"agentacct_record_section({', '.join(example_args)})."
    )


def require_reproducible_check(
    *,
    name: str,
    result: str,
    command: Any = None,
    files: Any = None,
    exit_code: Any = None,
    artifact_ref: Any = None,
    artifact_path: Any = None,
    artifact_url: Any = None,
    has_outcome_evidence: bool = False,
) -> None:
    """A machine check must be re-runnable or at least objectively anchored (R5).

    Three shapes satisfy this, in descending order of auditability:

    * a pointer -- `command`, `files`, or an artifact reference/path/url;
    * the before/after outcome lane, where a pair of recorded exit codes with
      their summaries is itself the evidence (the CLI and HTTP lanes record a
      repair this way and never name a command);
    * a specific check name plus an exit code, which records what ran and what it
      returned even when the exact invocation is not spelled out. Eleven of the
      336 checks in the real ledger have exactly this shape -- an integration
      suite named precisely, with its exit status and no verbatim command -- and
      refusing them would discard genuine evidence.

    What is refused is the record that says nothing: a generic name, no pointer,
    and no exit code.
    """
    if has_outcome_evidence or command or files or artifact_ref or artifact_path or artifact_url:
        return
    if exit_code is not None and not is_generic_check_name(name):
        return
    raise SemanticRecordError(
        f"machine check `{name}` (result={result}) records nothing a reviewer can re-run or inspect: "
        "pass `command` (the exact command), `files` (the files it covered), or `artifact_ref`/"
        "`artifact_path`/`artifact_url` (what it produced). A specific `name` with an `exit_code` also "
        "counts. If this was a manual observation, record it with agentacct_record_event instead."
    )


def is_generic_check_name(name: Any) -> bool:
    if not isinstance(name, str):
        return True
    stripped = name.strip()
    return len(stripped) < 4 or stripped.lower() in GENERIC_CHECK_NAMES


def require_check_identity(name: Any, *, command: Any = None, files: Any = None) -> None:
    """A check must be identifiable, because supersession keys on its name (R6).

    A specific name identifies it by itself. A generic name is tolerated only
    when something else identifies the check -- a command or a file list.
    """
    if not is_generic_check_name(name):
        return
    if command or files:
        return
    raise SemanticRecordError(
        f"machine check name {name!r} is too generic to identify the check; a later check with the "
        "same name would supersede this one. Use the exact check you ran, for example "
        'name="pytest tests/test_mcp.py" or name="pnpm build:web".'
    )


# --- the single entry point each lane calls ---------------------------------


def validate_semantic_record(
    *,
    semantic_kind: str | None,
    status: str,
    fields: dict[str, Any],
    transport: str | None = None,
) -> None:
    """Apply every rule that governs an agent-authored semantic record.

    ``semantic_kind`` is the ledger's own discriminator: "section" for a work
    section and "evidence" for a machine check. Anything else -- imported usage,
    a session observation, a finding disposition -- is machine-recorded and is
    deliberately not subject to these rules, because no agent authored it and a
    refusal would drop a fact instead of correcting a report.

    Raises ``SemanticRecordError`` with an agent-readable message.
    """
    if semantic_kind == "section":
        title = fields.get("section_title") or fields.get("title")
        # A title is required. Measured cost: 534 distinct sections in the real
        # ledger, of which 0 are untitled -- one single event out of 1,168 omits
        # one -- so this refuses nothing an agent actually records. What it
        # prevents is the UI substituting an internal id ("Untitled step -
        # Codex") for a name a reader can use, which is the placeholder the
        # canvas shows when this field is missing.
        if not has_readable_title(title):
            raise SemanticRecordError(
                "section_title is required and must contain readable text (at least 2 letters or "
                "digits), not only whitespace, punctuation or control characters. Use a short name "
                "for this unit of work, for example section_title=\"Add rate-limit to login\"."
            )
        require_terminal_outcome(
            status,
            summary=fields.get("summary"),
            blocker=fields.get("blocker"),
            next_step=fields.get("next_step"),
            section_id=str(fields.get("section_id") or ""),
            source=str(fields.get("source") or ""),
            title=collapse_display_text(title) if isinstance(title, str) else None,
        )
        return
    if semantic_kind == "evidence":
        # The before/after outcome lane records a repair: the two exit codes and
        # their summaries ARE the evidence, and it is a shape the CLI and HTTP
        # lanes use deliberately without naming a command. Validate it before the
        # name check, because a complete resolution may legitimately carry only
        # the default check name.
        has_outcome_evidence = bool(
            fields.get("before_summary") is not None or fields.get("after_summary") is not None
        )
        if has_outcome_evidence:
            require_reproducible_check(
                name=str(fields.get("name") or "check"),
                result=str(fields.get("result") or "unknown"),
                has_outcome_evidence=True,
            )
            return
        # A record that names no check at all is not a check report; the ledger
        # has machine-recorded evidence events (hook-observed checks, imported
        # activity) that carry a result and nothing else. Identity and
        # reproducibility are only meaningful once there is something to
        # identify, so they are skipped rather than guessed at.
        if fields.get("name") in (None, ""):
            return
        # Identity first: a check called "check" with nothing else cannot be
        # referred to at all, which is a more fundamental defect than a missing
        # pointer, and the message that names it is the more actionable one.
        require_check_identity(
            fields.get("name"),
            command=fields.get("command"),
            files=fields.get("files"),
        )
        require_reproducible_check(
            name=str(fields.get("name") or "check"),
            result=str(fields.get("result") or "unknown"),
            command=fields.get("command"),
            files=fields.get("files"),
            exit_code=fields.get("exit_code"),
            artifact_ref=fields.get("artifact_ref"),
            artifact_path=fields.get("artifact_path"),
            artifact_url=fields.get("artifact_url"),
            # The before/after lane records the exit codes and their summaries as
            # the evidence, so it satisfies reproducibility without a command.
        )
        return
    return


# Semantic kinds the ledger recognises for agent-authored records.
SECTION_SEMANTIC_KIND = "section"
EVIDENCE_SEMANTIC_KIND = "evidence"
