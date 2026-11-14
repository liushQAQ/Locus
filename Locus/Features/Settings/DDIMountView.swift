import SwiftUI

/// Developer Disk Image mount card (iOS 16 and below).
///
/// The lockdown location-simulation service only exists once the DDI is
/// mounted. This card does the whole mount on-device: status check →
/// download the signed image for this iOS version (≈ 8 MB, cached) →
/// upload + mount. No computer, no reboot dance.
@MainActor
final class DDIMountModel: ObservableObject {
    enum Phase: Equatable {
        case unknown
        case checking
        case unreachable
        case mounted
        case notMounted
        case downloading
        case mounting
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var versionHint: String?

    private var working: Bool {
        phase == .checking || phase == .downloading || phase == .mounting
    }

    func refresh() {
        guard !working else { return }
        phase = .checking
        Thread.detachNewThread {
            let mounted = DDIMounter.isDeveloperImageMounted()
            let version = LockdownPairService.lockdownStringValue(key: "ProductVersion")
            Task { @MainActor in
                self.versionHint = version.map { "iOS \($0)" }
                switch mounted {
                case .some(true): self.phase = .mounted
                case .some(false): self.phase = .notMounted
                case .none: self.phase = .unreachable
                }
            }
        }
    }

    func mount() {
        guard !working else { return }
        phase = .downloading
        Thread.detachNewThread {
            let result = DDIMounter.mount()
            Task { @MainActor in
                switch result {
                case .success:
                    self.phase = .succeeded
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    var statusLabel: String {
        switch phase {
        case .unknown: return "开发者镜像状态未知"
        case .checking: return "正在检查开发者镜像…"
        case .unreachable: return "先完成配对，才能检查镜像状态"
        case .mounted, .succeeded: return "开发者镜像已挂载"
        case .notMounted: return "开发者镜像未挂载"
        case .downloading: return "正在下载开发者镜像（约 8 MB，仅首次）…"
        case .mounting: return "正在挂载开发者镜像…"
        case .failed: return "挂载失败"
        }
    }

    var statusIsGood: Bool {
        phase == .mounted || phase == .succeeded
    }

    /// `.failed` carries an associated value, so it can't be compared with
    /// `==` — pattern-match instead.
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Phases from which the mount button may (re)start the flow.
    var canTriggerMount: Bool {
        switch phase {
        case .unknown, .notMounted, .unreachable, .failed: return true
        default: return false
        }
    }

    var statusIcon: String {
        if statusIsGood { return "checkmark.seal.fill" }
        return "exclamationmark.triangle.fill"
    }
}

struct DDIMountCard: View {
    @EnvironmentObject private var pairing: PairingStore
    @StateObject private var model = DDIMountModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                HStack(spacing: 6) {
                    Text(model.statusLabel)
                    if let hint = model.versionHint, model.phase != .unreachable {
                        Text("(\(hint))")
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                if model.phase == .checking || model.phase == .downloading || model.phase == .mounting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.statusIcon)
                        .foregroundStyle(model.statusIsGood ? LocusTheme.statusGood : LocusTheme.statusWarn)
                }
            }
            .font(.subheadline.weight(.semibold))

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.canTriggerMount {
                Button {
                    if model.phase == .unreachable || (model.isFailed && !pairing.hasLockdownPairing) {
                        // No pairing yet — the pairing button above is the fix.
                    } else {
                        model.mount()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.icloud")
                        Text("挂载开发者镜像")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.black)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!pairing.hasLockdownPairing)
                if !pairing.hasLockdownPairing {
                    Text("挂载前需要先完成本机配对。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text("镜像来自公共开发者镜像仓库（与 pymobiledevice3 / Xcode 同源），下载后缓存在本机，手机重启后无需重新下载——但重启后需要重新点一次挂载。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refresh() }
    }
}
