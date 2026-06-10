import SwiftUI

struct WorkspaceSectionView: View {
    let workspaceManager: WorkspaceManager
    @State private var showFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKSPACE")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(workspaceManager.currentURL.path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Change...") {
                showFilePicker = true
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                workspaceManager.update(path: url.path)
            }
        }
    }
}
