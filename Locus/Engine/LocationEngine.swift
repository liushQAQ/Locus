import Darwin
import Foundation
import idevice
import UIKit

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive
    // iOS 16 and below (lockdown) path
    case lockdownPairingMissing
    case lockdownPairingRead
    case lockdownConnect
    case lockdownSet

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "隧道 IP 无效。iOS 16 及以下保持默认即可（App 自动走 127.0.0.1）；iOS 17+ 一般填 10.7.0.1。"
        case .pairingRead: return "无法读取 RPPairing 文件。请用 idevice_pair 以 RPPairing 模式生成。"
        case .tunnelCreate: return "无法打开开发者隧道。请确认 LocalDevVPN 已在 Wi-Fi 下连接。"
        case .remoteServer: return "隧道已连上，但 RemoteXPC 握手失败。"
        case .simulationCreate: return "无法打开系统的位置模拟服务。"
        case .locationSet: return "设置模拟坐标失败。"
        case .locationClear: return "清除模拟位置失败。"
        case .notActive: return "当前没有模拟会话。"
        case .lockdownPairingMissing:
            return "没有 lockdown 配对记录。iOS 16 上请点“在本机配对”（弹窗点信任），或导入 lockdown 配对记录。"
        case .lockdownPairingRead:
            return "无法读取 lockdown 配对记录，请重新配对或重新导入。"
        case .lockdownConnect:
            return "连不上 lockdownd 定位服务。请检查：1) 开发者磁盘镜像已挂载（手机每次重启后，用电脑跑一次 pymobiledevice3 developer ddi mount）；2) 配对记录仍有效（必要时重新导入）；3) 若改过隧道 IP，请恢复默认。"
        case .lockdownSet:
            return "lockdown 位置模拟失败。请确认开发者磁盘镜像已挂载（pymobiledevice3 developer ddi mount）且配对记录有效。"
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        case 20: return .lockdownPairingMissing
        case 21: return .lockdownPairingRead
        case 22: return .lockdownConnect
        case 23: return .lockdownSet
        default: return .locationSet
        }
    }
}

/// Thin Swift wrapper around idevice’s developer location simulation.
///
/// Two paths:
/// - iOS 17+ : RemotePairing tunnel (`tunnel_create_rppairing` → RemoteXPC → DVT simulation).
/// - iOS 16- : lockdownd `com.apple.dt.simulatelocation` over the loopback tunnel.
///   Requires the Developer Disk Image to be mounted on the device (do it once per
///   reboot from a computer with `pymobiledevice3 developer ddi mount`).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    // Lockdown (iOS 16-) handles
    private static var lockdownProvider: OpaquePointer?
    private static var lockdownSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12
    private static let lockdownPairingMissingCode: Int32 = 20
    private static let lockdownPairingReadCode: Int32 = 21
    private static let lockdownConnectCode: Int32 = 22
    private static let lockdownSetCode: Int32 = 23

    /// iOS 16 and below use the lockdownd service; iOS 17+ use RemotePairing.
    private static let usesLockdown: Bool = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17
    }()

    static var isSessionActive: Bool { locationSimulation != nil || lockdownSimulation != nil }

    static func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        lockdownPairingPath: String?,
        deviceIP: String
    ) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.locationSet)
        queue.sync {
            let code: Int32
            if usesLockdown {
                code = lockdownSetLocked(
                    latitude: latitude,
                    longitude: longitude,
                    lockdownPairingPath: lockdownPairingPath,
                    deviceIP: deviceIP
                )
            } else {
                code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
            }
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    static func clear() -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.notActive)
        queue.sync {
            let code = clearLocked()
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    // MARK: - Shared cleanup

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        if let lockdownSimulation {
            lockdown_location_simulation_free(lockdownSimulation)
            self.lockdownSimulation = nil
        }
        if let lockdownProvider {
            idevice_provider_free(lockdownProvider)
            self.lockdownProvider = nil
        }
    }

    // MARK: - iOS 17+ path (RemotePairing / RSD)

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(remoteServerError)
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(simError)
            cleanup()
            return simulationCreate
        }
        // location_simulation_new consumes/owns remote server lifecycle alongside handle
        remoteServer = nil

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return locationSet
        }
        return ok
    }

    // MARK: - iOS 16 and below path (lockdownd com.apple.dt.simulatelocation)

    private static func lockdownSetLocked(latitude: Double, longitude: Double, lockdownPairingPath: String?, deviceIP: String) -> Int32 {
        if let lockdownSimulation {
            let lat = String(format: "%.7f", latitude)
            let lon = String(format: "%.7f", longitude)
            let setCode = lat.withCString { latPtr in
                lon.withCString { lonPtr in
                    lockdown_location_simulation_set(lockdownSimulation, latPtr, lonPtr)
                }
            }
            if let err = setCode {
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }

        guard let lockdownPairingPath, !lockdownPairingPath.isEmpty else {
            return lockdownPairingMissingCode
        }

        // 选路：LocalDevVPN 的默认 10.7.0.1 只存在于它的 utun 隧道里，而本机
        // lockdownd 在回环上可达。iOS16 路径先试 127.0.0.1（无需任何 VPN），
        // 失败再退回用户配置的 IP；自定义 IP 时行为不变。
        let candidates = deviceIP == "10.7.0.1" ? ["127.0.0.1", deviceIP] : [deviceIP]

        for candidate in candidates {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(62078).bigEndian // lockdownd
            let inetResult = candidate.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            guard inetResult == 1 else { return invalidIP }

            var pairingFile: OpaquePointer?
            if let pairingError = lockdownPairingPath.withCString({ idevice_pairing_file_read($0, &pairingFile) }) {
                idevice_error_free(pairingError)
                return lockdownPairingReadCode
            }
            guard let pairingFile else { return lockdownPairingReadCode }

            // idevice_tcp_provider_new consumes the pairing file on success (and the
            // docs make no promise about failure, so never free it here).
            var provider: OpaquePointer?
            let providerError = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    idevice_tcp_provider_new(
                        $0,
                        pairingFile,
                        "LocusLockdown",
                        &provider
                    )
                }
            }
            if let providerError {
                idevice_error_free(providerError)
                continue
            }
            guard let provider else { continue }

            var simulation: OpaquePointer?
            if let connectError = lockdown_location_simulation_connect(provider, &simulation) {
                idevice_error_free(connectError)
                idevice_provider_free(provider)
                continue
            }
            guard let simulation else {
                idevice_provider_free(provider)
                continue
            }

            lockdownProvider = provider
            lockdownSimulation = simulation
        }

        guard let lockdownSimulation else { return lockdownConnectCode }

        let lat = String(format: "%.7f", latitude)
        let lon = String(format: "%.7f", longitude)
        let setCode = lat.withCString { latPtr in
            lon.withCString { lonPtr in
                lockdown_location_simulation_set(lockdownSimulation, latPtr, lonPtr)
            }
        }
        if let setError = setCode {
            idevice_error_free(setError)
            cleanup()
            return lockdownSetCode
        }
        return ok
    }

    // MARK: - Clear (both paths)

    private static func clearLocked() -> Int32 {
        if usesLockdown {
            guard let lockdownSimulation else { return locationClear }
            let err = lockdown_location_simulation_clear(lockdownSimulation)
            cleanup()
            if let err {
                idevice_error_free(err)
                return lockdownSetCode
            }
            return ok
        }

        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
