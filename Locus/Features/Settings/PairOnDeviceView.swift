import SwiftUI

struct PairOnDeviceView: View {
    enum Mode {
        /// Settings sheet — Close toolbar, dismiss on Done.
        case sheet
        /// First-run setup — no toolbar; calls `onFinished` after success.
        case embedded
    }

    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var host = PairOnDeviceService()

    var mode: Mode = .sheet
    var onFinished: (() -> Void)?

    var body: some View {
        Group {
            if mode == .sheet {
                NavigationStack {
                    scrollContent
                        .background(Color.black.ignoresSafeArea())
                        .navigationTitle("在本机配对")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") {
                                    host.resetToIdle()
                                    dismiss()
                                }
                            }
                        }
                }
            } else {
                scrollContent
            }
        }
        .onChange(of: host.phase) { phase in
            if case .succeeded = phase {
                pairing.refresh()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, host.isBusy {
                _ = host.pin
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if mode == .sheet {
                    header
                } else {
                    embeddedIntro
                }

                steps

                statusCard

                if mode == .sheet {
                    tipCard
                }

                actions
            }
            .padding(mode == .embedded ? 16 : 20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("无需电脑")
                .font(.title2.weight(.bold))
            Text("Locus 会广播一个可配对主机，iOS 在开发者模式里主动连接，然后 Locus 显示 6 位验证码供你输入。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var embeddedIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按以下步骤操作")
                .font(.headline)
            Text("保持 Locus 在前台。你会短暂离开去设置 App，带验证码回来。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Tap Start pairing and allow Local Network + Location when asked.")
            step(2, "Allow notifications — the code can appear as a banner over Settings.")
            step(3, "Open Settings › Privacy & Security › Developer Mode › Pair with Locus → Pair.")
            step(4, "Enter your unlock passcode first. On the next prompt, type Locus’s 6-digit code.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(LocusTheme.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("如果验证码还没出现", systemImage: "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LocusTheme.accentSecondary)
            Text("在开发者模式确认期间保持本 App 监听，不要强退。若“与 Locus 配对”消失了，请停止/重新开始配对并重进开发者模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.accentSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 14) {
            switch host.phase {
            case .idle:
                Label("一切就绪", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            case .advertising:
                ProgressView()
                Text("等待设置操作…")
                    .font(.headline)
                Text("在开发者模式里点“与 Locus 配对”→“配对”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .deviceConnected:
                ProgressView()
                Text("iPhone 已连接")
                    .font(.headline)
                Text("正在生成 6 位验证码…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .awaitingPIN(let pin):
                Text("在设置里输入此验证码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(pin)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .tracking(10)
                    .monospacedDigit()
                    .foregroundStyle(LocusTheme.accent)
                    .textSelection(.enabled)
                Text("只会再弹一次，在你输完锁屏密码之后。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .succeeded:
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusGood)
                Text("配对成功")
                    .font(.title3.weight(.bold))
                Text(mode == .embedded
                     ? "Next we’ll set up LocalDevVPN."
                     : "RPPairing file saved. Connect LocalDevVPN, then teleport.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusWarn)
                Text("配对失败")
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        switch host.phase {
        case .idle, .failed:
            Button {
                host.acknowledgeFailure()
                host.start(pairingStore: pairing)
            } label: {
                Text(host.phase == .idle ? "Start pairing" : "Try again")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .succeeded:
            Button {
                if let onFinished {
                    onFinished()
                } else {
                    dismiss()
                }
            } label: {
                Text(mode == .embedded ? "Continue" : "Done")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .advertising, .deviceConnected, .awaitingPIN:
            Text({
                switch host.phase {
                case .awaitingPIN: return "Type the code above into the second Settings prompt."
                case .deviceConnected: return "Connected — code coming next."
                default: return "Waiting for iOS to connect… don’t force-quit Locus."
                }
            }())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}
