import AgentTermProtocol
import AgentTermTerminal
import SwiftUI

/// Picks any folder on the Mac to start an agent in.
struct BrowseSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    /// Set to pick a folder for something else than starting an agent in
    /// it: the sheet then opens at `start` and hands back the folder chosen.
    var start: String?
    var pickTitle = "Choose"
    var onPick: ((String) -> Void)?

    private var listing: DirectoryListing? { model.listing }
    private var name: String {
        guard let listing else { return "Folders" }
        return listing.isHome ? "Home" : (listing.path == "/" ? "Macintosh HD" : (listing.path as NSString).lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let listing {
                    List {
                        if let parent = listing.parent {
                            Button {
                                model.browse(parent)
                            } label: {
                                Label("Up to \(parent == "/" ? "Macintosh HD" : (parent as NSString).lastPathComponent)", systemImage: "arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                            .listRowBackground(Palette.panel)
                        }
                        ForEach(listing.folders, id: \.self) { folder in
                            Button {
                                model.browse((listing.path as NSString).appendingPathComponent(folder))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill").foregroundStyle(Palette.tint)
                                    Text(folder).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .listRowBackground(Palette.panel)
                        }
                        if listing.folders.isEmpty {
                            Text("No folders inside.")
                                .foregroundStyle(.secondary)
                                .listRowBackground(Palette.panel)
                        }
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    LoadingView("Loading the folders…")
                }
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.browse(nil)
                    } label: {
                        Image(systemName: "house")
                    }
                    .accessibilityLabel("Home folder")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let listing {
                    if let onPick {
                        Button {
                            onPick(listing.path)
                            dismiss()
                        } label: {
                            Text("\(pickTitle) \(name)")
                                .font(.headline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pick-folder")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Palette.panel)
                    } else {
                        StartHere(path: listing.path, name: name)
                    }
                }
            }
            .onAppear {
                if onPick != nil { model.browse(start) } else if model.listing == nil { model.browse(nil) }
            }
            // Where a folder was picked for something else is not where
            // "Open Another Folder" should open next.
            .onDisappear { if onPick != nil { model.forgetListing() } }
            // The alert on the main screen cannot appear over this sheet, so
            // a folder that cannot be opened is reported here.
            .alert("AgentTerm", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
        }
    }
}

/// Starts an agent in the folder being looked at, or keeps the folder.
private struct StartHere: View {
    @EnvironmentObject private var model: PhoneModel
    let path: String
    let name: String

    private var isListed: Bool { model.folders.contains(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Start in \(name)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(isListed ? "In Your Folders" : "Add to Folders") { model.addFolder(path) }
                    .font(.footnote.weight(.semibold))
                    .disabled(isListed)
            }
            LaunchGrid(folder: path, labelSuffix: " here", showsSSH: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Palette.panel)
        .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
    }
}
