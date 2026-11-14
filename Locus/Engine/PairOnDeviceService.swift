import Foundation
import idevice
import UIKit
import UserNotifications
import CoreLocation

/// Runs idevice's iOS 27+ pairable-host flow on-device.
///
/// Advertising uses Network.framework NWListener (Bonjour). Inbound TCP is
/// relayed to the Rust pairable-host on loopback. The 6-digit PIN is created
/// only after that connection + pair-setup handshake.
@MainActor
final class PairOnDeviceService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case awaitingPIN(String)
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pin: String?
    @Published private(set) var debugPort: UInt16?

    private var worker: Thread?
    private let callbackBox = PairCallbackBox()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private let keepAlive = PairingKeepAlive()
    private let audioKeepAlive = SilentAudioKeepAlive()
    private let advertiser = PairableHostAdvertiser()

    var isBusy: Bool {
        switch phase {
        case .advertising, .deviceConnected, .awaitingPIN: return true
        default: return false
        }
    }

    func start(pairingStore: PairingStore) {
        guard !isBusy else { return }
        phase = .advertising
        pin = nil
        debugPort = nil
        callbackBox.owner = self

        requestNotificationPermission()
        beginKeepAlive()

        _ = pairingStore.pairingURL
        try? FileManager.default.createDirectory(
            at: pairingStore.pairingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let outputPath = pairingStore.pairingURL.path
        let box = callbackBox

        worker = Thread {
            autoreleasepool {
                Self.runBlockingAccept(outputPath: outputPath, box: box)
            }
        }
        worker?.name = "locus.pairable-host"
        worker?.qualityOfService = .userInitiated
        worker?.start()
    }

    func acknowledgeFailure() {
        if case .failed = phase {
            teardown()
            phase = .idle
            pin = nil
        }
    }

    func resetToIdle() {
        teardown()
        phase = .idle
        pin = nil
        debugPort = nil
    }

    fileprivate func handleListening(
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        ver: String,
        minVer: String
    ) {
        debugPort = port
        advertiser.publish(
            port: port,
            serviceIdentifier: serviceIdentifier,
            name: name,
            model: model,
            authTag: authTag,
            ver: ver,
            minVer: minVer
        )
        phase = .advertising
        NSLog("[Locus] listening on %u, Bonjour id=%@", port, serviceIdentifier)
    }

    fileprivate func handleConnected() {
        phase = .deviceConnected
        Self.postPlainNotification(
            title: "Locus 已连接",
            body: "正在生成配对验证码…"
        )
    }

    fileprivate func handlePIN(_ value: String) {
        pin = value
        phase = .awaitingPIN(value)
        Self.postPINNotification(value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    fileprivate func handleSuccess() {
        pin = nil
        phase = .succeeded
        teardown()
        Self.postPlainNotification(
            title: "Locus 配对成功",
            body: "RPPairing 已就绪。连接 LocalDevVPN 后即可传送。"
        )
    }

    fileprivate func handleFailure(_ message: String) {
        pin = nil
        phase = .failed(message)
        teardown()
    }

    private func teardown() {
        advertiser.stop()
        endKeepAlive()
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        keepAlive.start()
        audioKeepAlive.start()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "locus.pairable-host") { [weak self] in
            self?.endKeepAlive()
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        keepAlive.stop()
        audioKeepAlive.stop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postPINNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locus 配对验证码"
        content.body = pin
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: "locus.pairing.pin", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func postPlainNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "locus.pairing.status.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func runBlockingAccept(outputPath: String, box: PairCallbackBox) {
        let name = "Locus"
        let model = "Mac17,7"

        var outFile: OpaquePointer?
        var peerDevice: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var altIRK = [UInt8](repeating: 0, count: 16)

        // New API: the Rust host listens AND advertises the
        // `_remotepairing-pairable-host._tcp` Bonjour service itself; Swift
        // only displays the PIN and may cancel via the token.
        let cancelToken = pairable_host_cancel_new()
        defer { if let cancelToken { pairable_host_cancel_free(cancelToken) } }

        let err: UnsafeMutablePointer<IdeviceFfiError>? = name.withCString { namePtr in
            model.withCString { modelPtr in
                pairable_host_accept(
                    namePtr,
                    modelPtr,
                    0,
                    pinCallbackTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    cancelToken,
                    &altIRK,
                    &peerDevice,
                    &outFile
                )
            }
        }
        if let peerDevice { rppairing_peer_device_free(peerDevice) }

        if let err {
            let message: String
            if let cMessage = err.pointee.message {
                message = String(cString: cMessage)
            } else {
                message = "未知配对错误（代码 \(err.pointee.code)）"
            }
            idevice_error_free(err)
            DispatchQueue.main.async { box.owner?.handleFailure(message) }
            return
        }

        guard let outFile else {
            DispatchQueue.main.async {
                box.owner?.handleFailure("配对完成，但未返回配对文件。")
            }
            return
        }

        defer { rp_pairing_file_free(outFile) }

        let parent = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let writeError = outputPath.withCString { path in
            rp_pairing_file_write(outFile, path)
        }
        if let writeError {
            let message: String
            if let cMessage = writeError.pointee.message {
                message = String(cString: cMessage)
            } else {
                message = "配对文件写入失败"
            }
            idevice_error_free(writeError)
            DispatchQueue.main.async {
                box.owner?.handleFailure("配对成功，但保存文件失败：\(message)")
            }
            return
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
        DispatchQueue.main.async { box.owner?.handleSuccess() }
    }
}

private final class PairingKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

final class PairCallbackBox: @unchecked Sendable {
    weak var owner: PairOnDeviceService?
}

/// C trampoline for `pairable_host_accept`'s single PIN callback.
private func pinCallbackTrampoline(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let box = Unmanaged<PairCallbackBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.handlePIN(value) }
}
