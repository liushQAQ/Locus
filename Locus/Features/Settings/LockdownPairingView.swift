import SwiftUI
import UniformTypeIdentifiers

/// iOS 16 and below pairing panel: on-device `lockdownd_pair` (Trust prompt)
/// plus manual import of a lockdown pairing record (pymobiledevice3 export).
struct LockdownPairingView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @StateObject private var pairer = LockdownPairer()
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow

            Button {
                pairer.reset()
                pairer.start(pairingStore: pairing)
            } label: {
                HStack(spacing: 8) {
                    if pairer.phase == .working {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                    Text("在本机配对")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(Capsule().fill(LocusTheme.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(pairer.phase == .working)

            if case .working = pairer.phase {
                Text("连接中…请保持这台 iPhone 解锁。出现“信任此电脑？”弹窗时，点“信任”。")
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .succeeded = pairer.phase {
                Text("配对成功，lockdown 配对记录已保存。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LocusTheme.statusGood)
            }

            if case .failed(let message) = pairer.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("导入记录…") { showImporter = true }
                    .font(.subheadline.weight(.semibold))
                Button("粘贴") {
                    do {
                        try pairing.importLockdownPairingFromClipboard()
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                }
                .font(.subheadline.weight(.semibold))
                if pairing.hasLockdownPairing {
                    Button("移除", role: .destructive) {
                        try? pairing.removeLockdownPairing()
                    }
                    .font(.subheadline)
                }
            }

            DDIMountCard()

            stepsCard
        }
    }

    private var statusRow: some View {
        Label {
            Text(pairing.hasLockdownPairing ? "lockdown 配对已就绪" : "尚无 lockdown 配对")
        } icon: {
            Image(systemName: pairing.hasLockdownPairing ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(pairing.hasLockdownPairing ? LocusTheme.statusGood : LocusTheme.statusWarn)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, "解锁手机后点“在本机配对”，弹出“信任此电脑？”时点“信任”。全程在手机上完成，无需电脑。")
            stepRow(2, "配对成功后点“挂载开发者镜像”（约 8 MB，仅首次下载；手机需要联网）。")
            stepRow(3, "手机每次重启后重新点一次“挂载开发者镜像”即可，配对记录长期有效。")
            stepRow(4, "不想本机配对？也可以在电脑上用 pymobiledevice3 导出配对记录后在这里导入。")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(LocusTheme.accent, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Document picker for lockdown pairing records.
struct LockdownPairingPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: PairingStore.supportedTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: (() -> Void)?

        init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel?()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}
