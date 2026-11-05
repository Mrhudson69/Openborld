import SwiftUI
import OpenborldCore

struct TransfersView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case completed = "Completed"
        case failed = "Failed"

        var id: String { rawValue }

        func matches(_ transfer: Transfer) -> Bool {
            switch self {
            case .all: true
            case .active: transfer.status.isActive
            case .completed: transfer.status == .completed || transfer.status == .skipped
            case .failed: transfer.status == .failed || transfer.status == .cancelled
            }
        }
    }

    private var transfers: [Transfer] {
        model.transfers.transfers.filter(filter.matches).reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if transfers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(transfers) { transfer in
                        TransferRow(transfer: transfer)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
        .navigationTitle("Transfers")
    }

    private var header: some View {
        HStack(spacing: Theme.Space.lg) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            if model.transfers.hasActivity {
                HStack(spacing: 6) {
                    ProgressView(value: model.transfers.overallFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                    Text(ByteFormat.rate(model.transfers.totalSpeed))
                        .font(Theme.Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Stepper(
                    value: Binding(
                        get: { model.settings.maxConcurrentTransfers },
                        set: {
                            model.settings.maxConcurrentTransfers = $0
                            model.transfers.maxConcurrent = $0
                        }
                    ),
                    in: 1...32
                ) {
                    Text("\(model.settings.maxConcurrentTransfers) at once")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .controlSize(.small)
            }

            if model.transfers.failedCount > 0 {
                Button("Retry Failed") { model.transfers.retryAllFailed() }
                    .controlSize(.small)
            }
            if model.transfers.hasActivity {
                Button("Cancel All") { model.transfers.cancelAll() }
                    .controlSize(.small)
            }
            Button("Clear Finished") { model.transfers.clearFinished() }
                .controlSize(.small)
                .disabled(!model.transfers.transfers.contains { $0.status.isFinished })
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 42)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: Theme.Icon.display, weight: .light))
                .foregroundStyle(Theme.Ink.secondary)
            Text(filter == .all ? "No transfers yet." : "Nothing \(filter.rawValue.lowercased()).")
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Ink.secondary)
            if filter == .all {
                Text("Copy files between panes, or drag them in from Finder.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.status == .running
                ? transfer.kind.symbol
                : transfer.status.symbol)
                .font(.system(size: Theme.Icon.lg))
                .foregroundStyle(transfer.status.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.name)
                        .font(Theme.Typo.bodyStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let group = transfer.groupName {
                        Text(group)
                            .font(.system(size: Theme.Icon.badge))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.Ink.secondary)
                    }

                    if transfer.kind == .serverSideCopy {
                        Label("Server-side", systemImage: "bolt.fill")
                            .font(.system(size: Theme.Icon.badge))
                            .foregroundStyle(.green)
                            .help("Copied by the provider — the data never left the cloud.")
                    }
                    Spacer(minLength: 0)
                }

                Text("\(transfer.source.label)  →  \(transfer.destination.label)")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if transfer.status == .running || transfer.status == .paused {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .frame(height: 3)
                }

                if let error = transfer.error {
                    Text(error)
                        .font(Theme.Typo.micro)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText)
                    .font(Theme.Typo.caption)
                    .monospacedDigit()
                    .foregroundStyle(transfer.status == .failed ? .red : .secondary)
                Text(detailText)
                    .font(Theme.Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .frame(width: 130, alignment: .trailing)

            controls
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenSummary)
    }

    /// One phrase per row. Progress is announced as a percentage because the
    /// bar itself conveys nothing to a screen reader.
    private var spokenSummary: String {
        var parts: [String] = [transfer.name, transfer.status.displayName]
        if transfer.status == .running, let size = transfer.size, size > 0 {
            parts.append("\(Int(transfer.fraction * 100)) percent")
            if let eta = transfer.estimatedTimeRemaining {
                parts.append("\(ByteFormat.duration(eta)) remaining")
            }
        }
        parts.append("from \(transfer.source.label) to \(transfer.destination.label)")
        if let error = transfer.error { parts.append("Error: \(error)") }
        return parts.joined(separator: ", ")
    }

    private var statusText: String {
        switch transfer.status {
        case .running:
            guard let size = transfer.size, size > 0 else {
                return ByteFormat.bytes(transfer.transferred)
            }
            return "\(ByteFormat.bytes(transfer.transferred)) of \(ByteFormat.bytes(size))"
        case .completed:
            return ByteFormat.bytes(transfer.size ?? transfer.transferred)
        default:
            return transfer.status.displayName
        }
    }

    private var detailText: String {
        switch transfer.status {
        case .running:
            var parts: [String] = []
            if transfer.speed > 1 { parts.append(ByteFormat.rate(transfer.speed)) }
            if let eta = transfer.estimatedTimeRemaining {
                parts.append("\(ByteFormat.duration(eta)) left")
            }
            return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
        case .completed:
            guard let duration = transfer.duration, duration > 0.2 else { return "Done" }
            let average = Double(transfer.transferred) / duration
            return average > 1 ? ByteFormat.rate(average) : "Done"
        case .queued:
            return "In queue"
        default:
            return ""
        }
    }

    /// Each control names the file it acts on, so a screen-reader user moving
    /// through a queue of twenty transfers can tell the Cancel buttons apart.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Theme.Space.hair) {
            switch transfer.status {
            case .running, .queued:
                IconButton(
                    symbol: "pause.fill",
                    label: "Pause",
                    detail: transfer.name,
                    size: Theme.Icon.badge
                ) { model.transfers.pause(transfer.id) }

                IconButton(
                    symbol: "xmark",
                    label: "Cancel",
                    detail: transfer.name,
                    size: Theme.Icon.badge
                ) { model.transfers.cancel(transfer.id) }

            case .paused:
                IconButton(
                    symbol: "play.fill",
                    label: "Resume",
                    detail: transfer.name,
                    size: Theme.Icon.badge
                ) { model.transfers.resume(transfer.id) }

                IconButton(
                    symbol: "xmark",
                    label: "Cancel",
                    detail: transfer.name,
                    size: Theme.Icon.badge
                ) { model.transfers.cancel(transfer.id) }

            case .failed, .cancelled:
                IconButton(
                    symbol: "arrow.clockwise",
                    label: "Retry",
                    detail: transfer.name,
                    size: Theme.Icon.badge
                ) { model.transfers.retry(transfer.id) }

            case .completed, .skipped:
                EmptyView()
            }
        }
        .frame(width: 58, alignment: .trailing)
    }
}

// MARK: - History

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.transfers.history.count) recorded transfers")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                Spacer()
                Button("Clear History") { model.transfers.clearHistory() }
                    .controlSize(.small)
                    .disabled(model.transfers.history.isEmpty)
            }
            .padding(.horizontal, Theme.Space.lg)
            .frame(height: 42)
            .background(.bar)

            Divider()

            if model.transfers.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: Theme.Icon.display, weight: .light))
                        .foregroundStyle(Theme.Ink.secondary)
                    Text("No transfer history yet.")
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.transfers.history) { record in
                        HStack(spacing: 10) {
                            Image(systemName: record.status.symbol)
                                .font(Theme.Typo.body)
                                .foregroundStyle(record.status.tint)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name)
                                    .font(Theme.Typo.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(record.sourceLabel)  →  \(record.destinationLabel)")
                                    .font(Theme.Typo.micro)
                                    .foregroundStyle(Theme.Ink.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let error = record.error {
                                    Text(error)
                                        .font(Theme.Typo.micro)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ByteFormat.bytes(record.size ?? record.transferred))
                                    .font(Theme.Typo.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Ink.secondary)
                                Text(ByteFormat.modified(record.finishedAt))
                                    .font(Theme.Typo.micro)
                                    .foregroundStyle(Theme.Ink.secondary)
                            }

                            if let average = record.averageSpeed {
                                Text(ByteFormat.rate(average))
                                    .font(Theme.Typo.micro)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Ink.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Activity History")
    }
}
