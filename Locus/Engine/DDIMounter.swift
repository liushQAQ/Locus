import Foundation
import UIKit
import idevice

/// On-device Developer Disk Image (DDI) handling for iOS 16 and below.
///
/// The `com.apple.dt.simulatelocation` lockdown service only exists once the
/// developer disk image is mounted — on stock flows a computer does this with
/// `pymobiledevice3 developer ddi mount` or Xcode. Here the app does the whole
/// thing itself over its loopback lockdown channel:
///
/// 1. `LookupImage` → already mounted?
/// 2. Resolve the device iOS version (`ProductVersion` via lockdown) and fetch
///    the matching signed image (dmg ≈ 8 MB + 128-byte signature) from the
///    same public repository pymobiledevice3 uses; cached in the app container.
/// 3. Upload + mount through the `com.apple.mobile.mobile_image_mover`
///    lockdown service.
enum DDIMounter {
    enum MountError: LocalizedError {
        case lockdown(String)
        case versionUnknown
        case downloadFailed(String)
        case developerModeDisabled

        var errorDescription: String? {
            switch self {
            case .lockdown(let detail):
                return "开发者镜像挂载失败：\(detail)"
            case .versionUnknown:
                return "无法读取系统版本号，请解锁手机后重试。"
            case .downloadFailed(let detail):
                return "开发者镜像下载失败：\(detail)（手机需要联网）"
            case .developerModeDisabled:
                return "设备报告开发者模式未开启。越狱机一般不受影响；若反复出现，请到 设置 → 隐私与安全性 → 开发者模式 打开。"
            }
        }
    }

    static let imageType = "Developer"
    static let repoBase = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/DeveloperDiskImages"

    // MARK: - Paths

    /// Cache dir for the downloaded image; reused across reboots (and across
    /// app reinstalls that keep the container).
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DDI", isDirectory: true)
    }

    static func imageCacheURL(version: String) -> URL {
        cacheDirectory
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("DeveloperDiskImage.dmg")
    }

    static func signatureCacheURL(version: String) -> URL {
        cacheDirectory
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("DeveloperDiskImage.dmg.signature")
    }

    // MARK: - Status

    /// Whether the developer image is currently mounted. `nil` = the lockdown
    /// channel itself is unreachable (no pairing / lockdown down).
    static func isDeveloperImageMounted() -> Bool? {
        withMounter { mounter in
            var signature: UnsafeMutablePointer<UInt8>?
            var signatureLen: UInt = 0
            let err = imageType.withCString {
                image_mounter_lookup_image(mounter, $0, &signature, &signatureLen)
            }
            defer {
                if let signature {
                    idevice_data_free(signature, UInt(signatureLen))
                }
            }
            return err == nil
        }
    }

    // MARK: - Mount

    /// Blocking mount flow — run on a worker thread.
    static func mount() -> Result<Void, MountError> {
        guard let version = Self.resolveVersion(), !version.isEmpty else {
            return .failure(.versionUnknown)
        }

        let cached: Result<(URL, URL), MountError> = ensureCachedImage(version: version)
        let (imageURL, signatureURL): (URL, URL)
        switch cached {
        case .failure(let error):
            return .failure(error)
        case .success(let urls):
            (imageURL, signatureURL) = urls
        }

        let outcome: Result<Void, MountError>? = withMounter { mounter in
            Self.mountWith(mounter: mounter, imageURL: imageURL, signatureURL: signatureURL)
        }
        guard let outcome else {
            return .failure(.lockdown("连不上 mobile_image_mover 服务。请先完成本机配对（弹窗点“信任”），解锁手机后重试。"))
        }
        return outcome
    }

    private static func mountWith(
        mounter: OpaquePointer,
        imageURL: URL,
        signatureURL: URL
    ) -> Result<Void, MountError> {
        // No LookupImage short-circuit: on iOS ≤16 LookupImage also matches
        // images cached on disk but NOT mounted (i.e. right after a reboot),
        // which would report a false "already mounted". Always upload+mount —
        // the device answers "already mounted" and that counts as success.

        // Developer mode gate (iOS 16 reports it; jailbroken devices usually pass).
        var devMode: Int32 = 0
        if let devErr = image_mounter_query_developer_mode_status(mounter, &devMode) {
            idevice_error_free(devErr)
            // Systems without the query — ignore.
        } else if devMode == 0 {
            return .failure(.developerModeDisabled)
        }

        let signatureData: Data
        do {
            signatureData = try Data(contentsOf: signatureURL)
        } catch {
            return .failure(.lockdown("读取签名文件失败"))
        }
        let image: Data
        do {
            image = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        } catch {
            return .failure(.lockdown("读取镜像文件失败"))
        }

        // 1) Upload image + signature bytes.
        let uploadErr = image.withUnsafeBytes { imageBytes in
            signatureData.withUnsafeBytes { signatureBytes in
                imageType.withCString { typePtr in
                    image_mounter_upload_image(
                        mounter,
                        typePtr,
                        imageBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        image.count,
                        signatureBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        signatureData.count
                    )
                }
            }
        }
        if let uploadErr {
            let message = LockdownPairService.message(of: uploadErr)
            idevice_error_free(uploadErr)
            if message.localizedCaseInsensitiveContains("already") {
                return .success(())
            }
            return .failure(.lockdown("镜像上传失败：\(message)"))
        }

        // 2) Mount.
        let mountErr = signatureData.withUnsafeBytes { signatureBytes in
            imageType.withCString { typePtr in
                image_mounter_mount_image(
                    mounter,
                    typePtr,
                    signatureBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    signatureData.count,
                    nil,
                    0,
                    nil
                )
            }
        }
        if let mountErr {
            let message = LockdownPairService.message(of: mountErr)
            idevice_error_free(mountErr)
            if message.localizedCaseInsensitiveContains("already mounted") {
                return .success(())
            }
            if message.localizedCaseInsensitiveContains("Developer mode") {
                return .failure(.developerModeDisabled)
            }
            return .failure(.lockdown("镜像挂载失败：\(message)"))
        }

        return .success(())
    }

    // MARK: - Image sourcing

    /// iOS version for the image lookup. Lockdown first (authoritative for a
    /// paired device), falling back to the local `UIDevice` — this app runs on
    /// the phone itself, so the local version *is* the device version.
    private static func resolveVersion() -> String? {
        if let v = LockdownPairService.lockdownStringValue(key: "ProductVersion")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
        let local = UIDevice.current.systemVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return local.isEmpty ? nil : local
    }

    private static func ensureCachedImage(version: String) -> Result<(URL, URL), MountError> {
        let imageURL = imageCacheURL(version: version)
        let signatureURL = signatureCacheURL(version: version)

        if FileManager.default.fileExists(atPath: imageURL.path),
           FileManager.default.fileExists(atPath: signatureURL.path) {
            return .success((imageURL, signatureURL))
        }

        do {
            try FileManager.default.createDirectory(
                at: imageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let image = try Self.fetch(urlString: "\(repoBase)/\(version)/DeveloperDiskImage.dmg")
            let signature = try Self.fetch(urlString: "\(repoBase)/\(version)/DeveloperDiskImage.dmg.signature")
            guard !image.isEmpty, !signature.isEmpty else {
                return .failure(.downloadFailed("镜像仓库中没有 iOS \(version) 的文件"))
            }
            try image.write(to: imageURL, options: .atomic)
            try signature.write(to: signatureURL, options: .atomic)
            return .success((imageURL, signatureURL))
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    /// Synchronous fetch (image ≈ 8 MB, signature 128 B — both quick).
    private static func fetch(urlString: String) throws -> Data {
        guard let url = URL(string: urlString) else {
            throw MountError.downloadFailed("URL 无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90

        var payload: Data?
        var fetchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                fetchError = error
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                fetchError = MountError.downloadFailed("HTTP \(http.statusCode)")
            } else {
                payload = data ?? Data()
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let fetchError {
            throw fetchError
        }
        guard let payload else {
            throw MountError.downloadFailed("空响应")
        }
        return payload
    }

    // MARK: - Mounter connection lifecycle

    /// Opens the image mounter over the best available lockdown transport and
    /// runs `body`, freeing both the mounter and its provider afterwards.
    private static func withMounter<T>(_ body: (OpaquePointer) -> T?) -> T? {
        // Preferred: explicit pairing file over loopback TCP — deterministic,
        // the stored record is exactly what the TLS handshake uses.
        if let provider = LoopbackTransport.makeProvider() {
            var mounter: OpaquePointer?
            let connectErr = image_mounter_connect(provider, &mounter)
            if let connectErr {
                idevice_error_free(connectErr)
                idevice_provider_free(provider)
                return nil
            }
            defer {
                if let mounter {
                    image_mounter_free(mounter)
                }
                idevice_provider_free(provider)
            }
            guard let mounter else { return nil }
            return body(mounter)
        }

        // Fallback: usbmuxd socket provider (unsandboxed installs).
        if let provider = usbmuxdProvider() {
            var mounter: OpaquePointer?
            let connectErr = image_mounter_connect(provider, &mounter)
            if let connectErr {
                idevice_error_free(connectErr)
                idevice_provider_free(provider)
                return nil
            }
            defer {
                if let mounter {
                    image_mounter_free(mounter)
                }
                idevice_provider_free(provider)
            }
            guard let mounter else { return nil }
            return body(mounter)
        }
        return nil
    }

    /// usbmuxd provider: enumerate the local device, then build a provider
    /// bound to the muxer (its pair-record store must hold our record —
    /// `LockdownPairService` saves it right after pairing).
    private static func usbmuxdProvider() -> OpaquePointer? {
        // Reachability probe BEFORE the FFI layer (sandboxed installs must
        // never touch the library — see UsbmuxdPreflight).
        guard UsbmuxdPreflight.isReachable() else { return nil }

        var connection: OpaquePointer?
        let connectError = "/var/run/usbmuxd".withCString {
            idevice_usbmuxd_new_unix_socket_connection($0, 3, &connection)
        }
        if let connectError {
            idevice_error_free(connectError)
            return nil
        }
        guard let connection else { return nil }

        var devices: UnsafeMutablePointer<OpaquePointer?>?
        var count: Int32 = 0
        if let err = idevice_usbmuxd_get_devices(connection, &devices, &count) {
            idevice_error_free(err)
            return nil
        }
        guard let devices, count > 0 else { return nil }
        // `devices` is the array of device handles itself (UsbmuxdDeviceHandle**
        // per the FFI header). Element 0 IS the first handle — the old code
        // took one indirection too many and dereferenced the device struct as
        // a pointer array, which crashed the app on every launch that reached
        // this path.
        guard let firstDevice = devices.pointee else {
            idevice_usbmuxd_device_list_free(devices, count)
            return nil
        }
        let deviceID = idevice_usbmuxd_device_get_device_id(firstDevice)
        let udid = idevice_usbmuxd_device_get_udid(firstDevice).map { ptr -> String in
            defer { idevice_string_free(ptr) }
            return String(cString: ptr)
        } ?? ""
        idevice_usbmuxd_device_list_free(devices, count)

        var addr: OpaquePointer?
        let addrError = "/var/run/usbmuxd".withCString {
            idevice_usbmuxd_unix_addr_new($0, &addr)
        }
        if let addrError {
            idevice_error_free(addrError)
            return nil
        }
        guard let addr else { return nil }

        var provider: OpaquePointer?
        let providerErr: UnsafeMutablePointer<IdeviceFfiError>? = udid.withCString { udidPtr in
            "LocusDDI".withCString { labelPtr in
                usbmuxd_provider_new(addr, 4, udidPtr, deviceID, labelPtr, &provider)
            }
        }
        if let providerErr {
            idevice_error_free(providerErr)
            return nil
        }
        return provider
    }
}

/// Loopback lockdown provider factory shared by the mounter.
///
/// Wraps the stored lockdown pairing record; TLS terminates on the device's
/// own lockdownd listener (port 62078), no computer involved.
enum LoopbackTransport {
    static func makeProvider() -> OpaquePointer? {
        let path = PairingStoreStatic.lockdownPairingPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = in_port_t(LockdownPairService.lockdownPort).bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        var pairingFile: OpaquePointer?
        if let err = path.withCString({
            idevice_pairing_file_read($0, &pairingFile)
        }) {
            idevice_error_free(err)
            return nil
        }
        guard let pairingFile else { return nil }

        var provider: OpaquePointer?
        let err = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                "LocusDDI".withCString { label in
                    idevice_tcp_provider_new(sockPtr, pairingFile, label, &provider)
                }
            }
        }
        if let err {
            idevice_error_free(err)
            // The provider consumes the pairing file on success; on failure
            // the docs make no promise — free it defensively.
            idevice_pairing_file_free(pairingFile)
            return nil
        }
        guard let provider else {
            idevice_pairing_file_free(pairingFile)
            return nil
        }
        return provider
    }
}

/// Read-only access to the stored pairing path without touching the MainActor
/// store (mount calls run on worker threads).
enum PairingStoreStatic {
    static var lockdownPairingPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
        return dir.appendingPathComponent(PairingStore.lockdownFileName).path
    }
}
