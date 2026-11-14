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
                return "连不上 lockdownd。请先连接 LocalDevVPN（隧道 IP 10.7.0.1）。"
            case .lockdown(let detail):
                return detail
            case .noRecord:
                return "配对完成，但未返回配对记录。"
            case .serialize:
                return "配对记录序列化失败。"
            }
        }
    }

    static func pair() -> Result<Data, PairError> {
        .failure(.lockdown(
            "本构建无法在手机上直接配对（内置 idevice 库版本较老，缺少 lockdownd_pair）。请在电脑上运行 `pymobiledevice3 pair`，然后把 ~/.pymobiledevice3/pairing_records/<udid>.plist 传到手机并在这里导入——挂载开发者磁盘镜像（DDI）本来也需要这条电脑连接。"
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
