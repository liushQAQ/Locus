import Foundation
import idevice

/// On-device lockdown pairing for iOS 16 and below.
///
/// Talks to this iPhone's *own* lockdownd and runs the standard lockdown pair
/// handshake — the same protocol a computer runs over USB, just aimed at the
/// loopback listener every device exposes on port 62078. The vendored idevice
/// library generates the host key + certificates; the device shows the
/// “信任此电脑？” prompt, and the resulting record is stored in the app
/// container for the later TLS sessions that simulate location.
///
/// Transport chain (first that connects wins):
/// 1. `/var/run/usbmuxd` unix socket — reachable from an unsandboxed install
///    (e.g. TrollStore, which preserves the `no-sandbox` entitlement).
/// 2. TCP `127.0.0.1:62078` — plain localhost networking, works sandboxed.
enum LockdownPairService {
    enum PairError: LocalizedError {
        case tunnelUnreachable(String)
        case lockdown(String)
        case noRecord
        case serialize

        var errorDescription: String? {
            switch self {
            case .tunnelUnreachable(let detail):
                return "连不上本机 lockdownd：\(detail)"
            case .lockdown(let detail):
                return detail
            case .noRecord:
                return "配对完成，但未返回配对记录。"
            case .serialize:
                return "配对记录序列化失败。"
            }
        }
    }

    static let systemBUID = "30142955-444094379208051516"
    static let lockdownPort: UInt16 = 62078

    static func pair() -> Result<Data, PairError> {
        // Preferred: usbmuxd unix socket — unsandboxed installs (e.g.
        // TrollStore, which keeps the no-sandbox entitlement) reach the local
        // muxer directly.
        if case .success(let data) = pairViaUsbmuxd() {
            return .success(data)
        }
        return pairViaLoopbackTCP()
    }

    // MARK: - Connection

    /// usbmuxd unix socket path: enumerate the local device, connect to its
    /// lockdown port through the muxer.
    private static func pairViaUsbmuxd() -> Result<Data, PairError> {
        // Reachability probe BEFORE entering the FFI layer: a sandboxed
        // install gets a graceful hint instead of a kernel denial deep inside
        // the library.
        guard UsbmuxdPreflight.isReachable() else {
            return .failure(.tunnelUnreachable("本机 usbmuxd 不可达（沙盒限制）。请用 TrollStore 安装本应用后重试。"))
        }

        var connection: OpaquePointer?
        let connectError = "/var/run/usbmuxd".withCString {
            idevice_usbmuxd_new_unix_socket_connection($0, 1, &connection)
        }
        if let connectError {
            idevice_error_free(connectError)
            return .failure(.tunnelUnreachable("本机 usbmuxd 套接字不可达（未越狱/沙盒安装时正常，走回环通道）"))
        }
        guard let connection else {
            return .failure(.tunnelUnreachable("usbmuxd 连接建立失败"))
        }

        var devices: UnsafeMutablePointer<OpaquePointer?>?
        var count: Int32 = 0
        if let listError = idevice_usbmuxd_get_devices(connection, &devices, &count) {
            idevice_error_free(listError)
            return .failure(.tunnelUnreachable("usbmuxd 未枚举到本机设备"))
        }
        guard let devices, count > 0 else {
            return .failure(.tunnelUnreachable("usbmuxd 设备列表为空"))
        }
        // `devices` is the array of device handles itself (UsbmuxdDeviceHandle**
        // per the FFI header). Element 0 IS the first handle — one more level
        // of indirection dereferences garbage and kills the process.
        guard let firstDevice = devices.pointee else {
            idevice_usbmuxd_device_list_free(devices, count)
            return .failure(.tunnelUnreachable("usbmuxd 设备列表为空"))
        }
        let deviceID = idevice_usbmuxd_device_get_device_id(firstDevice)
        let udid = idevice_usbmuxd_device_get_udid(firstDevice).map { ptr -> String in
            defer { idevice_string_free(ptr) }
            return String(cString: ptr)
        } ?? ""
        idevice_usbmuxd_device_list_free(devices, count)

        // connect_to_device consumes the muxer connection.
        var socket: OpaquePointer?
        let portError = "LocusPair".withCString { label in
            idevice_usbmuxd_connect_to_device(connection, deviceID, lockdownPort, label, &socket)
        }
        if let portError {
            idevice_error_free(portError)
            return .failure(.tunnelUnreachable("usbmuxd 无法转发 lockdownd 端口"))
        }
        guard let socket else {
            return .failure(.tunnelUnreachable("usbmuxd 转发返回空连接"))
        }

        var client: OpaquePointer?
        if let clientError = lockdownd_new(socket, &client) {
            idevice_error_free(clientError)
            idevice_free(socket)
            return .failure(.tunnelUnreachable("lockdownd 会话初始化失败"))
        }
        guard let client else {
            return .failure(.tunnelUnreachable("lockdownd 客户端创建失败"))
        }
        defer { lockdownd_client_free(client) }

        // Best effort: also stash the (about-to-be-created) record in usbmuxd's
        // own store so provider-based transports pick it up later. Needs a
        // fresh muxer connection because the previous one was consumed.
        if let record = pairOver(client: client) {
            savePairRecordToUsbmuxd(udid: udid, record: record)
            return .success(record)
        }
        return .failure(.lockdown("本机配对未完成：请解锁手机，弹出“信任此电脑？”时点“信任”后重试。"))
    }

    /// Plain loopback TCP: lockdownd listens on 62078 and speaks the same
    /// protocol iTunes Wi-Fi sync used over the network.
    private static func pairViaLoopbackTCP() -> Result<Data, PairError> {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = in_port_t(lockdownPort).bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        var socket: OpaquePointer?
        let connectError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_new_tcp_socket($0, idevice_socklen_t(MemoryLayout<sockaddr_in>.stride), "LocusPair", &socket)
            }
        }
        if let connectError {
            idevice_error_free(connectError)
            return .failure(.tunnelUnreachable("127.0.0.1:62078 连接失败（本机 lockdownd 不可达）"))
        }
        guard let socket else {
            return .failure(.tunnelUnreachable("127.0.0.1:62078 连接返回空句柄"))
        }

        var client: OpaquePointer?
        if let clientError = lockdownd_new(socket, &client) {
            idevice_error_free(clientError)
            idevice_free(socket)
            return .failure(.tunnelUnreachable("lockdownd 会话初始化失败"))
        }
        guard let client else {
            return .failure(.tunnelUnreachable("lockdownd 客户端创建失败"))
        }
        defer { lockdownd_client_free(client) }

        guard let record = pairOver(client: client) else {
            return .failure(.lockdown("本机配对未完成：请解锁手机，弹出“信任此电脑？”时点“信任”后重试。"))
        }
        return .success(record)
    }

    // MARK: - Pair handshake

    /// Runs `lockdownd_pair` on an open client; returns the raw plist bytes.
    private static func pairOver(client: OpaquePointer) -> Data? {
        let hostID = UUID().uuidString.uppercased()
        let hostName = "Locus"

        var record: OpaquePointer?
        let pairError = hostID.withCString { hostIDPtr in
            systemBUID.withCString { buidPtr in
                hostName.withCString { namePtr in
                    lockdownd_pair(client, hostIDPtr, buidPtr, namePtr, &record)
                }
            }
        }
        if let pairError {
            let message = Self.message(of: pairError)
            idevice_error_free(pairError)
            NSLog("[Locus] lockdownd_pair failed: %@", message)
            return nil
        }
        guard let record else { return nil }
        defer { idevice_pairing_file_free(record) }

        var buffer: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        if let serializeError = idevice_pairing_file_serialize(record, &buffer, &size) {
            idevice_error_free(serializeError)
            return nil
        }
        guard let buffer, size > 0 else { return nil }
        defer { idevice_data_free(buffer, UInt(size)) }
        return Data(bytes: buffer, count: Int(size))
    }

    ///usbmuxd keeps its own pair-record store; providers created from a muxer
    /// address read from it. Best effort — the app-container copy is what the
    /// loopback TCP path uses, so failure here is non-fatal.
    private static func savePairRecordToUsbmuxd(udid: String, record: Data) {
        guard !udid.isEmpty else { return }
        var connection: OpaquePointer?
        let connectError = "/var/run/usbmuxd".withCString {
            idevice_usbmuxd_new_unix_socket_connection($0, 2, &connection)
        }
        if let connectError {
            idevice_error_free(connectError)
            return
        }
        guard let connection else { return }

        record.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let mutable = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
            let saveError = udid.withCString {
                idevice_usbmuxd_save_pair_record(connection, $0, mutable, UInt(record.count))
            }
            if let saveError {
                idevice_error_free(saveError)
            }
        }
    }

    // MARK: - Helpers

    static func message(of error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let cMessage = error.pointee.message {
            return String(cString: cMessage)
        }
        return "错误代码 \(error.pointee.code)"
    }

    /// Reads a string value from lockdown (e.g. ProductVersion) over loopback.
    /// Used by the DDI mounter to pick the matching disk image.
    static func lockdownStringValue(key: String) -> String? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = in_port_t(lockdownPort).bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        var socket: OpaquePointer?
        let connectError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_new_tcp_socket($0, idevice_socklen_t(MemoryLayout<sockaddr_in>.stride), "LocusLockdown", &socket)
            }
        }
        if let connectError {
            idevice_error_free(connectError)
            return nil
        }
        guard let socket else { return nil }

        var client: OpaquePointer?
        if let clientError = lockdownd_new(socket, &client) {
            idevice_error_free(clientError)
            idevice_free(socket)
            return nil
        }
        defer { if let client { lockdownd_client_free(client) } }

        var value: UnsafeMutableRawPointer?
        let keyError = key.withCString { keyPtr in
            "".withCString { domainPtr in
                lockdownd_get_value(client, keyPtr, domainPtr, &value)
            }
        }
        if let keyError {
            idevice_error_free(keyError)
            return nil
        }
        guard let value else { return nil }
        defer { plist_free(value) }

        var length: UInt64 = 0
        guard let cString = plist_get_string_ptr(value, &length) else { return nil }
        return String(cString: cString)
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
                        if data.isEmpty {
                            self.phase = .failed(LockdownPairService.PairError.serialize.localizedDescription)
                        } else {
                            do {
                                try pairingStore.installLockdownPairingData(data)
                                self.phase = .succeeded
                            } catch {
                                self.phase = .failed(error.localizedDescription)
                            }
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
