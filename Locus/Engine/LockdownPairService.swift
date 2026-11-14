import Darwin
import Foundation
import idevice
import UIKit

/// On-device lockdown pairing for iOS 16 and below.
///
/// Talks to this iPhone's own lockdownd through the LocalDevVPN loopback tunnel
/// (10.7.0.1:62078) and runs `lockdownd_pair`. iOS shows the "Trust This
/// Computer?" prompt on screen — once accepted, the pairing record can be saved
/// and reused for the lockdown location simulation service.
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
                return "Pairing failed: \(detail). If iOS showed no Trust prompt, import a lockdown pairing record exported with pymobiledevice3 instead."
            case .noRecord:
                return "Paired but no pairing record was returned."
            case .serialize:
                return "Could not serialize the pairing record."
            }
        }
    }

    static let hostIDKey = "locus.lockdown.hostID"
    static let buidKey = "locus.lockdown.buid"

    /// Stable per-install host identity so re-pairing after the first Trust tap
    /// succeeds silently (iOS remembers the host).
    static var hostID: String {
        let d = UserDefaults.standard
        if let v = d.string(forKey: hostIDKey) { return v }
        let v = UUID().uuidString
        d.set(v, forKey: hostIDKey)
        return v
    }

    static var systemBUID: String {
        let d = UserDefaults.standard
        if let v = d.string(forKey: buidKey) { return v }
        let v = UUID().uuidString
        d.set(v, forKey: buidKey)
        return v
    }

    /// Blocking: connects to the device's own lockdownd and pairs. Call from a
    /// background thread — it waits for the on-screen Trust prompt.
    /// Returns the serialized pairing record bytes on success.
    static func pair() -> Result<Data, PairError> {
        // Give the user time to read and tap the Trust prompt.
        idevice_set_global_timeout(120)

        let ip = TunnelConfig.targetIP
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(62078).bigEndian
        let inetResult = ip.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return .failure(.tunnelUnreachable) }

        var ideviceHandle: OpaquePointer?
        let connectError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_new_tcp_socket(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusPair",
                    &ideviceHandle
                )
            }
        }
        if let connectError {
            let message = Self.message(of: connectError)
            idevice_error_free(connectError)
            return .failure(.lockdown(message))
        }
        guard let ideviceHandle else { return .failure(.tunnelUnreachable) }

        var lockdownClient: OpaquePointer?
        if let err = lockdownd_new(ideviceHandle, &lockdownClient) {
            let message = Self.message(of: err)
            idevice_error_free(err)
            return .failure(.lockdown(message))
        }
        guard let lockdownClient else { return .failure(.tunnelUnreachable) }
        defer { lockdownd_client_free(lockdownClient) }

        let hostID = Self.hostID
        let buid = Self.systemBUID
        var record: OpaquePointer?
        let pairError = hostID.withCString { hostPtr in
            buid.withCString { buidPtr in
                "Locus".withCString { namePtr in
                    lockdownd_pair(lockdownClient, hostPtr, buidPtr, namePtr, &record)
                }
            }
        }
        if let err = pairError {
            let message = Self.message(of: err)
            idevice_error_free(err)
            return .failure(.lockdown(message))
        }
        guard let record else { return .failure(.noRecord) }
        defer { idevice_pairing_file_free(record) }

        var dataPtr: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        if let err = idevice_pairing_file_serialize(record, &dataPtr, &size) {
            let message = Self.message(of: err)
            idevice_error_free(err)
            return .failure(.serialize)
        }
        guard let dataPtr, size > 0 else { return .failure(.serialize) }

        let bytes = Data(bytes: dataPtr, count: Int(size))
        idevice_data_free(dataPtr, size)
        return .success(bytes)
    }

    private static func message(of error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let cMessage = error.pointee.message {
            return String(cString: cMessage)
        }
        return "Unknown error (\(error.pointee.code))"
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
