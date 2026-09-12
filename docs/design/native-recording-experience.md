# Native recording and work review

Recording setup now opens in the main macOS window. A person chooses a coding
client, reviews the proposed user-level changes, installs, and receives explicit
activation guidance until a fresh event confirms capture. Existing work remains
reachable during recovery. Recording notices identify actionable causes without
treating a running daemon as proof of complete capture or usage attribution.

Work adds a live evidence timeline with a held history view, range navigation,
record inspection, file references and a scoped text export. Comparison has been
removed from the current interface, including its drag targets and saved slots.
New snapshots accumulate while someone investigates. Reviewing arrivals preserves
the original records, filters, disclosure choices and native scroll positions.

| Earlier baseline | Earlier information refinement (before the current simplification) |
|---|---|
| ![Previous native timeline](images/native-timeline-before.png) | ![Refined native timeline](images/native-timeline-after.png) |

[Setup at 185% text in a compact window](images/native-setup-large.png) keeps
the install scope and manual-merge qualification beside the action.

## Current Work hierarchy

Work answers: which task needs attention, what is happening, and what evidence
supports a selected record? Its hierarchy is **task → activity → selected record
→ supporting details**. The default task view has no comparison placeholder,
empty detail sidebar, range editor or zero-failure announcement. Search and view
mode remain close to activity. Current failures and data-quality limitations
remain visible when they occur.

The navigator is subordinate to the activity surface. Selecting a record opens
a dismissible inspector; Files, Artifacts and Record details disclose supporting
data on request. Task details has separate categories instead of expanding every
ledger at once. Full identifiers remain available, and real parent-section or
later-result links remain contextual to the selected record.

This revision also fixes an interaction inconsistency: opening a task from the
complete-store Attention queue must not replace that queue with only the recent
receipt page. The same authoritative projection now drives both collection and
navigator, including unavailable/empty/partial states and return focus.

The local review package `design-plans/native-macos-overhaul/work-simplification/`
contains the page-purpose review, per-state hierarchy, exact string-bearing source
inventory, independent collection/receipt audits and direct validation record.
The earlier 100-agent scores do not rate this revision. No human-usability or
mathematical-optimum claim is made.

## Review the change in this order

| Area | Main files | Invariant to inspect |
|---|---|---|
| Read-only setup proposal | `src/agentacct/setup_preview.py`, `cli.py`, `tests/test_setup_preview.py` | Generate managed snippets without running setup or returning unrelated existing values. Unsupported configuration stays unresolved. |
| Capture lookup | `v1_sessions.py`, `api.py`, `SetupCaptureLookup.swift`, `SetupCaptureObserver.swift` | Filter client before pagination; confirm only the selected client's event after the effective boundary. |
| Setup and recovery | `NativeSetupFlow.swift`, `NativeClientActivationView.swift`, `SetupModel.swift`, `RecordingSetupRoute.swift` | Review scope before installation; reconnect preserves existing client configuration and guarded recorder ownership. |
| Health | `RecordingHealth.swift`, `RecordingHealthViews.swift`, `RecordingConnectionHistory.swift`, `SourcesPane.swift` | Reachability, capture, importer health and historical coverage remain distinct. Current causes precede routine diagnostics. |
| Saved work | `SavedWorkSnapshot.swift`, `SavedWorkView.swift`, `GlanceClient.swift` | Saved responses belong to the same store, retain their own timestamps and cannot fall through to network writes. |
| Timeline data and navigation | `WorkTimelineModel.swift`, `WorkTimelineMemory.swift`, `WorkTimelineViewport.swift`, `WorkTimelineFocus.swift` | Event identity, chronology, source and held snapshots remain authoritative. Selection is independent of the reading position. |
| Timeline presentation and export | `WorkTimelineView.swift`, `WorkTimelineOverview.swift`, `WorkTimelineExport.swift` | No inferred causality or execution duration; export retains full identities and qualifications and includes only visible records. |
| Information hierarchy | `ContextHelp.swift`, `ReadingSize.swift`, `Theme.swift`, `UsagePane.swift`, `UsageCapacity.swift` | Optional explanation is available by hover and keyboard; failures, cost basis, incomplete capture and install scope stay visible. |
| Distributable recorder | `packaging/materialize-cli.py`, `freeze-cli.sh`, `build-app.sh` | Framework aliases become independent files only after all targets are proven inside the frozen output. External or cyclic aliases fail; the installer's no-link contract is preserved. |

The backend and native application are separate commits. Synthetic review
fixtures are included; frozen reviewer source copies and large image corpora
are local study artifacts, not production resources.

## Information placement

- Remove redundant labels and empty update counts. Keep space reserved for
  arrivals so a new count does not move held history.
- Put supplemental explanation in an information icon with native hover help
  and a selectable popover reachable by keyboard. Use named disclosures for
  structured detail such as exact identities, capture proof and diagnostics.
- Keep current status and material qualifications visible. Setup's scope and
  possible manual merge steps remain beside Install. Usage keeps cost basis and
  partial subtotals beside monetary values.
- Display no comparison workspace or empty inspector. A selected record opens
  optional details; closing restores the activity space. Time-range editing and
  export are available from Activity actions.
- Task status and activity take priority. The task navigator carries titles,
  outcomes, source and recency; usage, check history, sessions and coverage open
  as distinct categories in Task details.
- Current failures appear when present. Active filters show their scoped count
  and a clear action. Routine zero counts and refresh narration are omitted.
- Enlarged text reflows actions and evidence sections. Compact navigation keeps
  destination names in a picker instead of relying only on icons.

In the earlier information study, in the same 1120×860 synthetic timeline, the first evidence row moves from
vertical position 610 to 304: 306 points recovered. The control region contains
129 versus 46 OCR whitespace words in the final copy (43 in the frozen paired
candidate). The final copy adds the loaded-record qualifier beside the failure
count. This is rendered geometry, not measured
human comprehension or distraction. A separately preserved single-analyst
monitoring audit classifies incidental weighted units as 18/41 versus 2/18;
those classifications depend on the monitoring task and declared unit weights.

The earlier evaluation used 100 fresh evaluator agents: 50 baseline inspections and
50 masked paired comparisons across ten tasks and five contexts. The protocol
was fixed before review. Ordinal ratings, hard constraints, raw disagreements
and ten weight sensitivity variants are reported separately from machine tests.
Agents are not human participants, and preference between two candidates does
not establish a universal optimum. Final cohort results and post-freeze
dispositions are reported in the PR description. The complete sealed corpus is
retained locally in `design-plans/native-information-study/`; the content policy,
measurements and coverage audit are in
`design-plans/native-macos-overhaul/information-weight/`.

## Native review without installation

From the repository root:

```sh
swift build --package-path apps/agentacct -c release
apps/agentacct/.build/release/agentacct --native-review \
  design-plans/native-macos-overhaul/fixtures/live-progress.json
```

The scene picker includes setup, pending/failure/recovery, source health, saved
work, record details, and live sample progression. The fixture uses inert installer
callbacks and makes no live recorder requests. Use Reading at 100% and 185%,
including a 960×640 content window. A separate
`parallel-session-identity.json` fixture exercises similarly named session IDs.

## Verification and remaining limits

- The latest Swift release suite counts and native interaction checks are in
  the draft description. New regressions cover retired comparison bookmark
  keys, filtered export, clock warnings and authoritative Attention navigation.
  Existing cases retain partial-resolution, artifact-redaction, saved-timestamp,
  file-filter restoration and native scroll-position coverage.
- Python tests cover proposals for all four setup clients, reconnect ownership,
  session filtering before pagination, and timezone-independent timestamp bounds.
  Last backend suite: 2,852 passed; this Work refinement changes no Python source. Parent-process coverage is 88.05% of statements and
  78.63% of branches. The earlier native LLVM line coverage was 66.34%; this is not a coverage
  measurement of the later UI refinement. Standalone renders
  and native interaction checks are not merged into that unit-test profile.
- Seventy-eight local PNGs cover the baseline counterparts plus enlarged
  Dashboard and Usage. Native interaction checks separately verify history
  restoration, keyboard setup, help access and export. Earlier comparison checks
  remain historical evidence for the removed feature.
- The local macOS renderer is 26.5.1; canonical pixel references require
  26.6 (25G72). The dedicated remote candidate workflow also failed its renderer
  guard: GitHub supplies 26.6.2 (25G83). Ordinary CI builds and review renders
  passed, but pixel-reference verification is not established. No references
  were promoted and the guard remains intact.
- Coverage identifies exercised code, not correctness. Swift UI action paths,
  full VoiceOver use, operating-system Login Items approval, and every lifecycle
  interruption are not exhaustively established by the local checks.
- Every interactive synthetic setup scene uses an inert installer and process
  runner, even inside a distributable app. A failure-Retry regression test
  verifies this boundary; preloaded screenshot state alone is insufficient.

Packaging requires a clean source commit and an embedded CLI carrying the same
provenance. Source edits alone do not update an installed app or recorder.
The installed-app smoke check caught an output mismatch that unit tests alone
missed: [PyInstaller preserves framework aliases](https://www.pyinstaller.org/en/v6.0.0/CHANGES.html),
while the recorder installer deliberately rejects symlinks. The freeze now
materializes bounded internal aliases before smoke testing and stamping output;
the app build also rejects any remaining links. Regression fixtures include
framework chains, outside targets, cycles, broken links and special files.
