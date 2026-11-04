import SwiftUI
import UIKit

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 把一个文件夹打包成 zip，再交给系统分享面板。
struct ExportButton: View {
    let title: String
    let folder: URL
    let archiveName: String

    @State private var isWorking = false
    @State private var file: ExportFile?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                export()
            } label: {
                HStack {
                    Label(title, systemImage: "square.and.arrow.up")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .sheet(item: $file) { item in
            ActivitySheet(url: item.url)
        }
    }

    private func export() {
        isWorking = true
        errorMessage = nil
        let source = folder
        let name = archiveName
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Storage.exportArchive(of: source, named: name) }
            DispatchQueue.main.async {
                isWorking = false
                switch result {
                case .success(let url):
                    file = ExportFile(url: url)
                case .failure(let error):
                    errorMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
