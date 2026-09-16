import SwiftUI

/// The recorded check table, on screen.
///
/// `dimensions.evidence.checks[]` has always carried a complete evidence
/// table — each run's name, result words, exit code, evidence type, revision,
/// files and summary — and no surface in the app rendered a single row of it.
/// The reviewer saw a tally ("1/1 passed · 1 earlier run failed") with no way
/// to see the runs it counted.
///
/// Two rules the table exists to keep:
/// * EARLIER RUNS ARE SHOWN, GREYED — never hidden. A fail → pass recovery is
///   the story the receipt is for, and it is only legible as two rows.
/// * The header tally counts the FRONTIER only (`history_run` rows are
///   excluded from it by the reducer), so a history row never reads as a peer.
///
/// Every word is the payload's: `result_label`, `revision_label`,
/// `command_state_text`, `note_text`, `revision_contradiction_text`,
/// `check_tally_text`. The table composes none of them.
struct RecordChecksSection: View {
    let receipt: Receipt
    /// The record page's selection channel: choosing a row selects the same
    /// recorded event in the activity surface below.
    var layers: WorkRecordLayers? = nil
    @State private var expandedID: String?

    private var evidence: ReceiptEvidenceDim { receipt.dimensions.evidence }

    /// Time order, oldest first, with undated runs last in payload order. The
    /// reducer already emits each earlier run immediately before the run that
    /// replaced it; sorting by recorded time preserves exactly that.
    private var rows: [ReceiptCheck] {
        (evidence.checks ?? []).enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.at, rhs.element.at) {
                case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    var body: some View {
        if rows.isEmpty {
            // A task with no recorded runs still names that state — the tally
            // carries the reducer's own words for it.
            Text(ReceiptCheckRunsPresentation(evidence: evidence).rowText)
                .workFont(.body).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("work.record.checks.empty")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    row(check)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work.record.checks")
        }
    }

    // MARK: one run

    @ViewBuilder
    private func row(_ check: ReceiptCheck) -> some View {
        let history = check.historyRun == true || check.superseded == true
        let expanded = expandedID == check.id
        VStack(alignment: .leading, spacing: 6) {
            Button { activate(check) } label: {
                HStack(alignment: .top, spacing: Space.m) {
                    RecordCheckResultGlyph(check: check).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PayloadAbsence.text(check.title) ?? PayloadAbsence.text(check.name)
                             ?? PayloadAbsence.text(check.evidenceType) ?? PayloadAbsence.checkResult)
                            .workFont(.rowLabel)
                            // A superseded run is HISTORY, not noise: greyed,
                            // still legible, never removed.
                            .foregroundStyle(history ? Theme.muted : Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: Space.s) {
                            Text(PayloadAbsence.text(check.resultLabel) ?? PayloadAbsence.checkResult)
                                .workFont(.caption)
                                .foregroundStyle(resultTint(check, history: history))
                            if let code = check.exitCode {
                                Text("Exit \(code)").workFont(.dataSmall).foregroundStyle(Theme.muted)
                            }
                            if let type = PayloadAbsence.text(check.evidenceType) {
                                Text(type).workFont(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            if let source = PayloadAbsence.text(check.sourceLabel) {
                                Text(source).workFont(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        // The reducer's named result/exit-code disagreement,
                        // directly under the exit code it disagrees with.
                        if let note = PayloadAbsence.text(check.noteText) {
                            Label(note, systemImage: "exclamationmark.triangle")
                                .workFont(.caption).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(check.revisionText)
                            .workFont(FieldFont.qualifier).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                        // A stamped revision that cannot contain the paths the
                        // check declared. The reducer decides and words it.
                        if let contradiction = PayloadAbsence.text(check.revisionContradictionText) {
                            Label(contradiction, systemImage: "exclamationmark.triangle")
                                .workFont(.caption).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let summary = PayloadAbsence.text(check.summary) {
                            Text(summary).workFont(.caption).foregroundStyle(Theme.muted)
                                .lineLimit(expanded ? nil : 1)
                        }
                        if let files = check.files, !files.isEmpty {
                            Text(files.joined(separator: " · "))
                                .workFont(.dataSmall).foregroundStyle(Theme.muted)
                                .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SurfaceButtonStyle())
            .accessibilityIdentifier("work.record.checks.row.\(check.id)")
            .accessibilityLabel(spokenLabel(check))
            if expanded { detail(check) }
        }
    }

    /// The facts that would crowd a resting row: how the command was handled,
    /// how many runs this identity has, and the supersession pointers that make
    /// a recovery navigable in both directions.
    @ViewBuilder
    private func detail(_ check: ReceiptCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = PayloadAbsence.text(check.commandStateText) {
                Text(command).workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let runs = check.runsTotal, runs > 1 {
                Text("\(runs) recorded runs of this check").workFont(.caption).foregroundStyle(Theme.muted)
            }
            if let superseding = PayloadAbsence.text(check.supersededByEventId) {
                factRow("Replaced by", superseding)
            }
            if let earlier = PayloadAbsence.text(check.supersedesCheckEventId) {
                factRow("Replaces", earlier)
                if let basis = PayloadAbsence.text(check.supersedesBasis) {
                    factRow("On the authority of", basis)
                }
            }
            if let definition = PayloadAbsence.text(check.supersededDefinition) {
                Text(definition).workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let absent = check.revisionAbsentFiles, !absent.isEmpty {
                factRow("Absent at that revision", absent.joined(separator: " · "))
            }
            if let scope = PayloadAbsence.text(check.scope) { factRow("Scope", scope) }
            if let event = PayloadAbsence.text(check.eventId) { factRow("Event", event) }
        }
        .textSelection(.enabled)
        .padding(.bottom, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("work.record.checks.detail.\(check.id)")
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            CapsLabel(text: label)
            Text(value).workFont(.dataSmall).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultTint(_ check: ReceiptCheck, history: Bool) -> Color {
        if check.isResolvedFailure { return Theme.coral }
        if history { return Theme.muted }
        return CheckResultTone(payload: check.resultTone).tint(pass: Theme.ink)
    }

    private func spokenLabel(_ check: ReceiptCheck) -> String {
        [PayloadAbsence.text(check.title) ?? PayloadAbsence.text(check.name),
         PayloadAbsence.text(check.resultLabel),
         check.exitCode.map { "Exit \($0)" },
         PayloadAbsence.text(check.evidenceType),
         check.revisionText,
         PayloadAbsence.text(check.noteText)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// A row both expands its own detail and selects the matching record in
    /// the activity surface, so the table and the canvas/list never disagree
    /// about what the reviewer is looking at.
    private func activate(_ check: ReceiptCheck) {
        expandedID = expandedID == check.id ? nil : check.id
        if let event = PayloadAbsence.text(check.eventId) { layers?.selectEvent(event) }
    }
}

/// A recorded run's result mark. Shape carries the state — open for a failure
/// a later run replaced — so colour is never the only carrier and the
/// interactive accent is never a data mark.
struct RecordCheckResultGlyph: View {
    let check: ReceiptCheck

    var body: some View {
        let tone = CheckResultTone(payload: check.resultTone)
        let history = check.historyRun == true || check.superseded == true
        Group {
            if check.isResolvedFailure {
                Image(systemName: "exclamationmark.arrow.circlepath")
            } else if history {
                Image(systemName: "clock.arrow.circlepath")
            } else {
                switch tone {
                case .pass: Image(systemName: "checkmark.circle")
                case .failure: Image(systemName: "xmark.circle")
                case .notRun: Image(systemName: CheckResultTone.notRun.symbol)
                }
            }
        }
        .workFont(.caption)
        .foregroundStyle(check.isResolvedFailure ? Theme.coral
                         : history ? Theme.muted
                         : tone.tint(pass: Theme.chartNeutral))
        .frame(width: 14, alignment: .center)
        .accessibilityHidden(true)  // the row's label names the result in words
    }
}
