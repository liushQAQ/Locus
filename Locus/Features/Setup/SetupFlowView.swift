import SwiftUI
import UniformTypeIdentifiers

/// First-run walkthrough: welcome → pairing → LocalDevVPN → map.
/// Skipped when `SetupGate.isComplete` (see `LocusApp`).
struct SetupFlowView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession

    var onFinished: () -> Void

    @State private var step: Step
    @State private var appear = false
    @State private var showImporter = false
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @StateObject private var ddiModel = DDIMountModel()
    @Environment(\.scenePhase) private var scenePhase

    enum Step: Int {
        case welcome
        case pairing
        case ddi
        case vpn
    }

    init(initialStep: Step = .welcome, onFinished: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinished = onFinished
    }

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    /// iOS 16 and below use the lockdownd path (Developer Disk Image + lockdown pairing).
    private var usesLockdownEngine: Bool {
        if #available(iOS 17.0, *) { return false }
        return true
    }

    /// Steps this install actually walks through; iOS 16 ends at the DDI page
    /// (no LocalDevVPN needed — the loopback lockdown channel carries it).
    private var steps: [Step] {
        if usesLockdownEngine {
            return [.welcome, .pairing, .ddi]
        }
        if supportsOnDevicePairing {
            return [.welcome, .pairing, .vpn]
        }
        return [.welcome, .pairing, .vpn]
    }

    private var pairingPageIntro: String {
        if supportsOnDevicePairing {
            return "Locus 需要一次性配对才能修改你的位置。之后需要在设置里确认一个短验证码。"
        }
        if usesLockdownEngine {
            return "Locus 需要一次性的 lockdown 配对，才能在这台手机上设置位置。弹窗出现时请点“信任”。"
        }
        return "从电脑导入一个配对文件——Locus 用它在这台手机上安全地设置位置。"
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                Group {
                    switch step {
                    case .welcome:
                        welcomePage
                    case .pairing:
                        pairingPage
                    case .ddi:
                        ddiPage
                    case .vpn:
                        vpnPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { appear = true }
            localDevVPNInstalled = LocalDevVPN.isInstalled
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                localDevVPNInstalled = LocalDevVPN.isInstalled
            }
        }
        .onChange(of: step) { newStep in
            if newStep == .vpn {
                localDevVPNInstalled = LocalDevVPN.isInstalled
            }
        }
        .onChange(of: pairing.hasPairingFile) { hasFile in
            if hasFile, step == .welcome || step == .pairing {
                SetupGate.markInProgress()
                withAnimation { step = usesLockdownEngine ? .ddi : .vpn }
            }
        }
        .onChange(of: pairing.hasLockdownPairing) { hasFile in
            if hasFile, step == .welcome || step == .pairing {
                SetupGate.markInProgress()
                withAnimation { step = usesLockdownEngine ? .ddi : .vpn }
            }
        }
        .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                        withAnimation { step = .vpn }
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Soft map-adjacent atmosphere (no flat fill).
            RadialGradient(
                colors: [
                    LocusTheme.accent.opacity(0.22),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.18, blue: 0.28).opacity(0.9),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()

            // Subtle grid suggestion of a map without competing with copy.
            GeometryReader { geo in
                Path { path in
                    let spacing: CGFloat = 44
                    for x in stride(from: 0, through: geo.size.width, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for y in stride(from: 0, through: geo.size.height, by: spacing) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
            }
            .ignoresSafeArea()
        }
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(steps, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? LocusTheme.accent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step.rawValue + 1) 步 / 共 \(steps.count) 步")
    }

    // MARK: - Welcome

    @ViewBuilder
    private var logoIcon: some View {
        let icon = Image(systemName: "location.north.circle.fill")
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(LocusTheme.accent)
        if #available(iOS 17.0, *) {
            icon.symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: appear)
        } else {
            icon
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 20) {
                logoIcon
                    .opacity(appear ? 1 : 0)
                    .scaleEffect(appear ? 1 : 0.85)

                VStack(spacing: 10) {
                    Text("Locus")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .tracking(-0.5)

                    Text("虚拟你的位置\n无需电脑")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 14) {
                Text("简单设置，约两分钟。")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                primaryButton("开始使用") {
                    SetupGate.markInProgress()
                    withAnimation { step = .pairing }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .opacity(appear ? 1 : 0)
        }
    }

    // MARK: - Pairing

    private var pairingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接这台 iPhone")
                    .font(.title.weight(.bold))
                Text(pairingPageIntro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)

            if supportsOnDevicePairing {
                PairOnDeviceView(mode: .embedded) {
                    withAnimation { step = .vpn }
                }
                .environmentObject(pairing)
            } else if usesLockdownEngine {
                LockdownPairingView()
                    .padding(.horizontal, 24)
                    .environmentObject(pairing)
                    .environmentObject(session)
            } else {
                importPairingCard
                    .padding(.horizontal, 24)
                Spacer()
                VStack(spacing: 12) {
                    primaryButton("导入配对文件") {
                        showImporter = true
                    }
                    Button {
                        do {
                            try pairing.importPairingFromClipboard()
                            withAnimation { step = .vpn }
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    } label: {
                        Text("从剪贴板粘贴")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .locusGlass(.interactive, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private var importPairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepRow(1, "在 Mac 上运行 idevice_pair 生成 RPPairing 配对文件。")
            stepRow(2, "隔空投送/分享到 Locus，或复制 plist 文本。")
            stepRow(3, "点“导入”；若文件选择器打不开（LiveContainer 环境）就用“从剪贴板粘贴”。")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(LocusTheme.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Developer Disk Image (iOS 16 and below)

    private var ddiPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 22) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(LocusTheme.accent)

                VStack(spacing: 10) {
                    Text("挂载开发者镜像")
                        .font(.title.weight(.bold))

                    Text("iOS 16 的定位模拟服务在开发者磁盘镜像（DDI）里。点一次挂载即可——镜像约 8 MB，只下载一次，缓存在手机里。全程无需电脑。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DDIMountCard()
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                primaryButton(ddiModel.phase == .mounted || ddiModel.phase == .succeeded ? "完成" : "稍后再挂载，先完成设置") {
                    onFinished()
                }
                Text("以后也可以在 设置 → 配对 里随时挂载。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .onAppear {
            if ddiModel.phase == .unknown {
                ddiModel.refresh()
            }
        }
    }

    // MARK: - LocalDevVPN

    private var vpnPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 22) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(LocusTheme.accent)

                VStack(spacing: 10) {
                    Text(localDevVPNInstalled ? "Connect LocalDevVPN" : "还差一个 App")
                        .font(.title.weight(.bold))

                    Text(localDevVPNInstalled
                         ? "LocalDevVPN 已安装。打开它开启 Locus 需要的私有隧道，然后回到这里。"
                         : "LocalDevVPN 会建立一条私有隧道，Locus 通过它与手机定位系统通信。装好并开启后即可开始虚拟位置。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if localDevVPNInstalled {
                        tipRow(systemImage: "checkmark.circle.fill", title: "已安装", detail: "这台 iPhone 上已有 LocalDevVPN。")
                        tipRow(systemImage: "power.circle.fill", title: "连接", detail: "点下面打开它并启动隧道，完成后会自动回到 Locus。")
                    } else {
                        tipRow(systemImage: "arrow.down.app.fill", title: "安装", detail: "从 App Store 获取 LocalDevVPN。")
                        tipRow(systemImage: "power.circle.fill", title: "连接", detail: "打开它并开启 VPN，默认 IP 不要改。")
                    }
                    tipRow(systemImage: "wifi", title: "首次虚拟请在 Wi-Fi 下进行", detail: "第一次虚拟位置请在 Wi-Fi 环境下启动，之后切到蜂窝网络也能继续生效。")
                }
                .padding(18)
                .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    if localDevVPNInstalled {
                        LocalDevVPN.openInstalled()
                    } else {
                        LocalDevVPN.openAppStore()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: localDevVPNInstalled ? "lock.shield.fill" : "apple.logo")
                        Text(localDevVPNInstalled ? "打开 LocalDevVPN" : "获取 LocalDevVPN")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.primary)
                    .locusGlass(.interactive, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                primaryButton("已连接，继续") {
                    onFinished()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func tipRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(LocusTheme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(LocusTheme.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gate

enum SetupGate {
    static let defaultsKey = "locus.setupComplete"
    static let inProgressKey = "locus.setupInProgress"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var isInProgress: Bool {
        UserDefaults.standard.bool(forKey: inProgressKey)
    }

    static func markInProgress() {
        UserDefaults.standard.set(true, forKey: inProgressKey)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        UserDefaults.standard.set(false, forKey: inProgressKey)
    }

    /// Already paired *during* this walkthrough → the page after pairing
    /// (DDI on iOS 16-, LocalDevVPN on iOS 17+).
    /// Fresh install → welcome. Already-paired upgrades are handled in `LocusApp`.
    static func initialStep(hasPairingFile: Bool, hasLockdownPairing: Bool) -> SetupFlowView.Step {
        if #available(iOS 17.0, *) {
            if hasPairingFile, isInProgress { return .vpn }
            return .welcome
        }
        if hasLockdownPairing, isInProgress { return .ddi }
        return .welcome
    }
}
