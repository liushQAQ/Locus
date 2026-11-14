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
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not open the developer tunnel. Is LocalDevVPN connected on Wi‑Fi?"
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        case .lockdownPairingMissing:
            return "No lockdown pairing record. On iOS 16: tap “Pair on this iPhone” (accept the Trust prompt), or import a lockdown pairing record."
        case .lockdownPairingRead:
            return "Could not read the lockdown pairing record. Re-pair or re-import it."
        case .lockdownConnect:
            return "Could not reach the lockdownd location service. Check: 1) LocalDevVPN connected, 2) Developer Disk Image mounted (run “pymobiledevice3 developer ddi mount” on your computer once after every reboot), 3) pairing record still valid."
        case .lockdownSet:
            return "Lockdown location simulation failed. Make sure the Developer Disk Image is mounted (pymobiledevice3 developer ddi mount) and the pairing record is valid."
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

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(62078).bigEndian // lockdownd
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingFile: OpaquePointer?
        if let pairingError = lockdownPairingPath.withCString({ idevice_pairing_file_read($0, &pairingFile) }) {
            idevice_error_free(pairingError)
            return lockdownPairingReadCode
        }
        guard let pairingFile else { return lockdownPairingReadCode }

        // idevice_tcp_provider_new consumes the pairing file on success (and the
        // docs make no promise about failure, so never free it here).
        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new(
                    $0,
                    pairingFile,
                    "LocusLockdown",
                    &lockdownProvider
                )
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            return lockdownConnectCode
        }
        guard let lockdownProvider else { return lockdownConnectCode }

        if let connectError = lockdown_location_simulation_connect(lockdownProvider, &lockdownSimulation) {
            idevice_error_free(connectError)
            idevice_provider_free(lockdownProvider)
            self.lockdownProvider = nil
            return lockdownConnectCode
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
