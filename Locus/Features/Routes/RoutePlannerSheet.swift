import CoreLocation
import SwiftUI

struct RoutePlannerSheet: View {
    @Binding var start: CLLocationCoordinate2D?
    @Binding var end: CLLocationCoordinate2D?
    @Binding var isRouting: Bool
    var onBuild: () -> Void
    var onPlay: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void
    var onUseDrawn: () -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("道路路线") {
                    Button("以当前落点/虚拟点为起点") {
                        start = session.simulated ?? session.pin
                    }
                    Button("以当前落点为终点") {
                        end = session.pin
                    }
                    LabeledContent("起点") {
                        Text(coordText(start)).font(.caption.monospaced())
                    }
                    LabeledContent("End") {
                        Text(coordText(end)).font(.caption.monospaced())
                    }
                    Button {
                        onBuild()
                    } label: {
                        if isRouting {
                            ProgressView()
                        } else {
                            Label("沿道路规划步行/驾车路线", systemImage: "road.lanes")
                        }
                    }
                    .disabled(isRouting)
                }

                Section("播放 / 手绘 / GPX") {
                    Button {
                        onUseDrawn()
                    } label: {
                        Label("使用地图手绘路径", systemImage: "pencil.tip")
                    }
                    Button(action: onPlay) {
                        Label("沿路线行进", systemImage: "play.fill")
                    }
                    Button(action: onImportGPX) {
                        Label("导入 GPX", systemImage: "square.and.arrow.down")
                    }
                    Button(action: onExportGPX) {
                        Label("导出 GPX", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Text("路线沿 Apple Maps 的道路/步道按所选交通方式规划，速度带轻微随机波动，行动更接近真人。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("路线")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func coordText(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "—" }
        return String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }
}
