import Darwin

/// Pure-POSIX reachability probe for the on-device usbmuxd socket.
///
/// Runs *before* any idevice FFI: in a sandboxed install the kernel denies the
/// connect() with EPERM and callers degrade gracefully, while an unsandboxed
/// install (TrollStore keeps `no-sandbox`) reaches the local muxer. Keeping
/// the probe outside the FFI means a sandbox denial can never take the
/// process down — the library layer is only entered once this socket is
/// proven connectable.
enum UsbmuxdPreflight {
    static let socketPath = "/var/run/usbmuxd"

    /// `true` when a unix-socket connect() to usbmuxd succeeds right now.
    /// Local sockets connect immediately — no timeout needed.
    static func isReachable(path: String = socketPath) -> Bool {
        let pathBytes = Array(path.utf8CString)   // includes trailing NUL
        guard pathBytes.count <= 104 else { return false }  // sun_path cap

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        var connected = false
        withUnsafeMutablePointer(to: &addr) { pointer in
            // Darwin sockaddr_un: { sun_len(1) | sun_family(1) | sun_path[104] }
            let sunPath = UnsafeMutableRawPointer(pointer)
                .advanced(by: 2)
                .assumingMemoryBound(to: CChar.self)
            pathBytes.withUnsafeBufferPointer { buffer in
                _ = memcpy(sunPath, buffer.baseAddress, pathBytes.count)
            }
            connected = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        return connected
    }
}
