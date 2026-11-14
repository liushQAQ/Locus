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
                    Text("Pair on this iPhone")
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
                Text("Connecting… Keep this iPhone unlocked. When the “Trust This Computer?” popup appears, tap Trust.")
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .succeeded = pairer.phase {
                Text("Paired. The lockdown pairing record is saved.")
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
                Button("Import record…") { showImporter = true }
                    .font(.subheadline.weight(.semibold))
                Button("Paste") {
                    do {
                        try pairing.importLockdownPairingFromClipboard()
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                }
                .font(.subheadline.weight(.semibold))
                if pairing.hasLockdownPairing {
                    Button("Remove", role: .destructive) {
                        try? pairing.removeLockdownPairing()
                    }
                    .font(.subheadline)
                }
            }

            stepsCard
        }
    }

    private var statusRow: some View {
        Label {
            Text(pairing.hasLockdownPairing ? "Lockdown pairing installed" : "No lockdown pairing")
        } icon: {
            Image(systemName: pairing.hasLockdownPairing ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(pairing.hasLockdownPairing ? LocusTheme.statusGood : LocusTheme.statusWarn)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, "Tap “Pair on this iPhone” while this iPhone is unlocked, then tap Trust in the popup.")
            stepRow(2, "Already paired on a computer? Export the record with pymobiledevice3 (it lives in ~/.pymobiledevice3/pairing_records) and Import it here.")
            stepRow(3, "After every reboot, mount the Developer Disk Image once from a computer: pymobiledevice3 developer ddi mount")
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
