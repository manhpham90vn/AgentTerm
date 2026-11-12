import AgentTermProtocol
import SwiftUI

/// Where the app opens: the Macs this iPhone is paired with. Picking one
/// goes into its sessions, files and settings; pairing another adds it here.
struct MacsScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var forgetting: SavedHost?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.hosts) { host in
                        Button {
                            model.enter(host)
                        } label: {
                            MacRow(host: host, isCurrent: host.id == model.pairing?.id)
                        }
                        .buttonStyle(.plain)
                        // Its name alone, for VoiceOver and for the tests.
                        .accessibilityLabel(host.name)
                        .accessibilityIdentifier("mac-row")
                        .contextMenu {
                            Button(role: .destructive) {
                                forgetting = host
                            } label: {
                                Label("Forget This Mac", systemImage: "xmark.circle")
                            }
                        }
                    }
                    Button {
                        model.showPairSheet = true
                    } label: {
                        Label("Pair Another Mac…", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
                    }
                    .padding(.top, 6)
                    .accessibilityIdentifier("pair-another")
                    Text("\(AppVersion.label) · protocol \(agenttermProtocolVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Macs")
            .sheet(isPresented: $model.showPairSheet) {
                NavigationStack {
                    PairView(addingAnother: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.showPairSheet = false }
                            }
                        }
                }
                .environmentObject(model)
                .preferredColorScheme(.dark)
            }
            .confirmationDialog(
                "Forget \(forgetting?.name ?? "this Mac")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                titleVisibility: .visible, presenting: forgetting
            ) { host in
                Button("Forget", role: .destructive) { model.forget(host) }
            } message: { host in
                Text("Sessions keep running on \(host.name). To connect again you pair with it once more.")
            }
            .alert("AgentTerm", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
        }
    }
}

/// One paired Mac: its name, where it is reached, and whether it is the
/// one connected now.
private struct MacRow: View {
    @EnvironmentObject private var model: PhoneModel
    let host: SavedHost
    let isCurrent: Bool

    private var detail: String {
        guard isCurrent else { return host.host }
        switch model.status {
        case .connected:
            let count = model.sessions.count
            return count == 0 ? "Connected" : (count == 1 ? "Connected · 1 session" : "Connected · \(count) sessions")
        case .connecting: return "Connecting…"
        case .offline: return "Not reachable right now"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isCurrent && model.status == .connected ? Palette.tint : Color.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name).font(.headline).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
        .contentShape(Rectangle())
    }
}
