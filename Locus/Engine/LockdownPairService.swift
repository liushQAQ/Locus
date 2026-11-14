import Foundation

/// On-device lockdown pairing for iOS 16 and below.
///
/// The vendored `libidevice_ffi.a` was built from an idevice revision that
/// predates `lockdownd_pair`, so pairing through the loopback tunnel is not
/// available in this build. The flow directs users to export a lockdown
/// pairing record with pymobiledevice3 on a computer
/// (`~/.pymobiledevice3/pairing_records/<udid>.plist`) and import it here —
/// the same computer connection is required for DDI mounting anyway.
enum LockdownPairService {
    enum PairError: LocalizedError {
        case tunnelUnreachable
        case lockdown(String)
        case noRecord
        case serialize

        var errorDescription: String? {
            switch self {
            case .tunnelUnreachable:
                return "Could not reach lockdownd. Connect LocalDevVPN first (Tunnel IP 10.7.0.1)."
            case .lockdown(let detail):
                return detail
            case .noRecord:
                return "Paired but no pairing record was returned."
            case .serialize:
                return "Could not serialize the pairing record."
            }
        }
    }

    static func pair() -> Result<Data, PairError> {
        .failure(.lockdown(
            "On-device lockdown pairing is unavailable in this build (the bundled idevice library predates lockdownd_pair). On a computer run `pymobiledevice3 pair`, then import ~/.pymobiledevice3/pairing_records/<udid>.plist here — the same connection is needed for DDI mounting anyway."
        ))
    }
}

/// Observable wrapper so UI can drive the blocking pair call on a worker thread.
@MainActor
final class LockdownPairer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func start(pairingStore: PairingStore) {
        guard phase != .working else { return }
        phase = .working

        Thread.detachNewThread {
            autoreleasepool {
                let result = LockdownPairService.pair()
                Task { @MainActor in
                    switch result {
                    case .success(let data):
                        do {
                            try pairingStore.installLockdownPairingData(data)
                            self.phase = .succeeded
                        } catch {
                            self.phase = .failed(error.localizedDescription)
                        }
                    case .failure(let error):
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func reset() {
        phase = .idle
    }
}
