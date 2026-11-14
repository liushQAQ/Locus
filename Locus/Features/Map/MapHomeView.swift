import MapKit
import SwiftUI

/// Shared camera command between the iOS 17 modern map and the iOS 16 map.
/// (`MKCoordinateRegion` itself is not `Equatable`, hence the wrapper.)
struct CameraRequest: Equatable {
    var latitude: Double
    var longitude: Double
    var meters: CLLocationDistance

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            latitudinalMeters: meters,
            longitudinalMeters: meters
        )
    }

    static func == (lhs: CameraRequest, rhs: CameraRequest) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude && lhs.meters == rhs.meters
    }
}

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var search = PlaceSearchCompleter()
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeEnd: CLLocationCoordinate2D?
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var isRouting = false
    @State private var showRouteSheet = false
    @State private var showGPXImporter = false
    @State private var drawnPath: [CLLocationCoordinate2D] = []
    @State private var drawMode = false
    /// Shared camera command: both map flavors (iOS 17 / iOS 16) react to it.
    @State private var cameraRequest: CameraRequest?
    /// Set when the pin comes from search / a named place so starring keeps the title.
    @State private var pinPlaceName: String?

    var body: some View {
        ZStack(alignment: .top) {
            // Keep the map inside the safe layout bounds so tap positions match
            // finger position (full-bleed shifts conversions up by status-bar height).
            mapLayer
                .background(Color.black.ignoresSafeArea())

            topChrome
        }
        .onAppear {
            session.startLocationUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let url = note.object as? URL else { return }
            importGPX(url)
        }
        .fileImporter(isPresented: $showGPXImporter, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importGPX(url)
            }
        }
        .sheet(isPresented: $showRouteSheet) {
            RoutePlannerSheet(
                start: $routeStart,
                end: $routeEnd,
                isRouting: $isRouting,
                onBuild: buildRoadRoute,
                onPlay: playRoute,
                onImportGPX: { showGPXImporter = true },
                onExportGPX: exportGPX,
                onUseDrawn: {
                    routeCoords = RouteBuilder.sample(coordinates: drawnPath, every: 10)
                    drawnPath.removeAll()
                    drawMode = false
                }
            )
        }
    }

    // MARK: - Map flavors

    @ViewBuilder
    private var mapLayer: some View {
        if #available(iOS 17.0, *) {
            ModernMapView(
                drawnPath: $drawnPath,
                drawMode: drawMode,
                routeCoords: routeCoords,
                cameraRequest: $cameraRequest,
                onPinPlaced: { pinPlaceName = nil }
            )
        } else {
            LegacyMapView(
                drawnPath: $drawnPath,
                drawMode: drawMode,
                routeCoords: routeCoords,
                cameraRequest: $cameraRequest,
                onPinPlaced: { pinPlaceName = nil }
            )
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var topChrome: some View {
        if #available(iOS 17.0, *) {
            chromeContent.safeAreaPadding(.top, 8)
        } else {
            chromeContent.padding(.top, 8)
        }
    }

    private var chromeContent: some View {
        VStack(spacing: 10) {
            StatusBarView()

            searchBar

            if !searchText.isEmpty && !search.results.isEmpty {
                searchResults
            }

            HStack(alignment: .center, spacing: 10) {
                mapChromeButtons
                Spacer(minLength: 0)
                locateButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $searchText)
                .textInputAutocapitalization(.words)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit {
                    searchFocused = false
                }
                .onChange(of: searchText) { value in
                    search.query = value
                }
            if searchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    search.query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear and dismiss keyboard")
            }
            if searchFocused {
                Button("Done") {
                    searchFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(12)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.results.prefix(5), id: \.self) { item in
                Button {
                    select(completion: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3)
            }
        }
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mapChromeButtons: some View {
        HStack(spacing: 4) {
            chromeIconButton("square.3.layers.3d") {
                session.mapStyleIndex = (session.mapStyleIndex + 1) % 3
            }
            chromeIconButton("point.topleft.down.to.point.bottomright.curvepath") {
                showRouteSheet = true
            }
            chromeIconButton(drawMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip.crop.circle") {
                drawMode.toggle()
                if !drawMode { drawnPath.removeAll() }
            }
            .foregroundStyle(drawMode ? LocusTheme.accentSecondary : .primary)

            if session.pin != nil {
                chromeIconButton("star.circle") {
                    if let pin = session.pin {
                        let name = session.suggestedFavoriteName(for: pin, fallback: pinPlaceName)
                        session.addFavorite(name: name, coordinate: pin)
                    }
                }
            }
        }
        .padding(6)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var locateButton: some View {
        Button {
            searchFocused = false
            goToCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
        .contentShape(Circle())
        .accessibilityLabel("Current location")
    }

    // MARK: - Camera commands

    /// Centers on the spoofed fix while spoofing, otherwise the real GPS —
    /// never the leftover teleport pin.
    private func goToCurrentLocation() {
        let meters: CLLocationDistance = 900
        if session.isSpoofing, let sim = session.simulated {
            requestCamera(center: sim, meters: meters)
        } else if let real = session.realCoordinate {
            requestCamera(center: real, meters: meters)
        } else {
            requestCamera(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                meters: 2000
            )
        }
    }

    private func requestCamera(center: CLLocationCoordinate2D, meters: CLLocationDistance) {
        cameraRequest = CameraRequest(latitude: center.latitude, longitude: center.longitude, meters: meters)
    }

    private func chromeIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func select(completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                let coord = item.placemark.coordinate
                let title = item.name ?? completion.title
                await MainActor.run {
                    session.pin = coord
                    pinPlaceName = title
                    requestCamera(center: coord, meters: 1200)
                    searchText = ""
                    search.query = ""
                    searchFocused = false
                    session.addFavorite(name: title, coordinate: coord)
                    session.pushNamedRecent(name: title, coordinate: coord)
                }
            }
        }
    }

    private func buildRoadRoute() {
        guard let start = routeStart ?? session.simulated ?? session.pin,
              let end = routeEnd else {
            session.lastError = "Set a route start and end."
            return
        }
        isRouting = true
        Task {
            do {
                let coords = try await RouteBuilder.roadRoute(from: start, to: end, mode: session.travelMode)
                await MainActor.run {
                    routeCoords = coords
                    isRouting = false
                }
            } catch {
                await MainActor.run {
                    isRouting = false
                    session.lastError = error.localizedDescription
                }
            }
        }
    }

    private func playRoute() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard path.count >= 2 else {
            session.lastError = "Build or draw a route first."
            return
        }
        showRouteSheet = false
        session.followRoute(path, pairing: pairing)
    }

    private func importGPX(_ url: URL) {
        do {
            let coords = try GPXCodec.parse(url)
            routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
            if let first = coords.first {
                session.pin = first
                requestCamera(center: first, meters: 2000)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func exportGPX() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard !path.isEmpty else {
            session.lastError = "Nothing to export."
            return
        }
        let gpx = GPXCodec.export(path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
        do {
            try gpx.data(using: .utf8)?.write(to: url)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.keyWindow?.rootViewController {
                root.present(av, animated: true)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

// MARK: - iOS 17+ modern map

@available(iOS 17.0, *)
private struct ModernMapView: View {
    @EnvironmentObject private var session: SpoofSession

    @Binding var drawnPath: [CLLocationCoordinate2D]
    let drawMode: Bool
    let routeCoords: [CLLocationCoordinate2D]
    @Binding var cameraRequest: CameraRequest?
    var onPinPlaced: () -> Void

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pinSelected = false
    @State private var isDraggingPin = false
    @State private var suppressNextMapTap = false

    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic)
        }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()

                if let pin = session.pin {
                    Annotation("", coordinate: pin, anchor: .bottom) {
                        MapDropPin(
                            selected: pinSelected,
                            isDragging: isDraggingPin,
                            onSelect: {
                                suppressNextMapTap = true
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                    pinSelected.toggle()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    suppressNextMapTap = false
                                }
                            },
                            onRemove: {
                                suppressNextMapTap = true
                                withAnimation {
                                    session.pin = nil
                                    pinSelected = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    suppressNextMapTap = false
                                }
                            },
                            onDragBegan: {
                                suppressNextMapTap = true
                                pinSelected = false
                                isDraggingPin = true
                            },
                            onDragMoved: { globalPoint in
                                if let coord = proxy.convert(globalPoint, from: .global) {
                                    session.pin = coord
                                }
                            },
                            onDragEnded: {
                                isDraggingPin = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    suppressNextMapTap = false
                                }
                            }
                        )
                    }
                }
                if let sim = session.simulated {
                    Annotation("Spoof", coordinate: sim) {
                        ZStack {
                            Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
                            Circle().fill(LocusTheme.accent).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                if routeCoords.count > 1 {
                    MapPolyline(coordinates: routeCoords)
                        .stroke(LocusTheme.accent, lineWidth: 5)
                }
                if drawnPath.count > 1 {
                    MapPolyline(coordinates: drawnPath)
                        .stroke(LocusTheme.accentSecondary, style: StrokeStyle(lineWidth: 4, dash: [6, 4]))
                }
            }
            .mapStyle(mapStyle)
            .mapControlVisibility(.hidden)
            .onTapGesture { point in
                guard !suppressNextMapTap, !isDraggingPin else { return }
                pinSelected = false
                placePin(at: point, proxy: proxy)
            }
        }
        .onChange(of: cameraRequest) { request in
            if let request {
                position = .region(request.region)
            }
        }
        .onChange(of: session.pin?.latitude) { newValue in
            if newValue == nil { pinSelected = false }
        }
    }

    private func placePin(at point: CGPoint, proxy: MapProxy) {
        guard let coord = proxy.convert(point, from: .local) else { return }
        if drawMode {
            drawnPath.append(coord)
        } else {
            session.pin = coord
            onPinPlaced()
        }
    }
}

// MARK: - iOS 16 legacy map (MKMapView)

/// MKPointAnnotation whose `coordinate` setter reports back while MKMapView
/// drags it (the map kit writes through setCoordinate during long-press drags).
final class DragPinAnnotation: MKPointAnnotation {
    var onCoordinateChange: ((CLLocationCoordinate2D) -> Void)?

    override var coordinate: CLLocationCoordinate2D {
        get { super.coordinate }
        set {
            super.coordinate = newValue
            onCoordinateChange?(newValue)
        }
    }
}

/// Observable state so the hosted SwiftUI pin view re-renders on selection/drag.
final class LegacyPinUIState: ObservableObject {
    @Published var selected = false
    @Published var isDragging = false
}

private struct LegacyMapView: UIViewRepresentable {
    @EnvironmentObject private var session: SpoofSession

    @Binding var drawnPath: [CLLocationCoordinate2D]
    let drawMode: Bool
    let routeCoords: [CLLocationCoordinate2D]
    @Binding var cameraRequest: CameraRequest?
    var onPinPlaced: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isPitchEnabled = false
        map.mapType = context.coordinator.mapType
        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
            latitudinalMeters: 40000,
            longitudinalMeters: 40000
        )

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        context.coordinator.attach(map: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        // Environment objects resolve by now; hand live references to the coordinator.
        coordinator.session = session
        coordinator.onPinPlaced = onPinPlaced
        coordinator.drawnPathBinding = $drawnPath
        coordinator.drawMode = drawMode
        coordinator.mapType = mapType(for: session.mapStyleIndex)
        map.mapType = coordinator.mapType

        // Camera command
        if let request = cameraRequest, request != coordinator.lastCameraRequest {
            coordinator.lastCameraRequest = request
            map.setRegion(request.region, animated: true)
        }

        // Pin annotation
        if let pin = session.pin {
            if let existing = coordinator.pinAnnotation {
                let same = existing.coordinate.latitude == pin.latitude
                    && existing.coordinate.longitude == pin.longitude
                if !same {
                    existing.coordinate = pin
                }
            } else {
                let annotation = DragPinAnnotation()
                annotation.coordinate = pin
                annotation.onCoordinateChange = { [weak coordinator] coord in
                    coordinator?.didDragPin(to: coord)
                }
                coordinator.pinAnnotation = annotation
                map.addAnnotation(annotation)
            }
        } else if let existing = coordinator.pinAnnotation {
            map.removeAnnotation(existing)
            coordinator.pinAnnotation = nil
            coordinator.pinState.selected = false
        }

        // Spoof annotation
        if let sim = session.simulated {
            if let existing = coordinator.spoofAnnotation {
                existing.coordinate = sim
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = sim
                coordinator.spoofAnnotation = annotation
                map.addAnnotation(annotation)
            }
        } else if let existing = coordinator.spoofAnnotation {
            map.removeAnnotation(existing)
            coordinator.spoofAnnotation = nil
        }

        // Overlays (route + drawn path)
        coordinator.syncOverlays(map: map, routeCoords: routeCoords, drawnPath: drawnPath)
    }

    private func mapType(for index: Int) -> MKMapType {
        switch index {
        case 1: return .hybrid
        case 2: return .satellite
        default: return .standard
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapView: MKMapView?
        weak var session: SpoofSession?
        var onPinPlaced: (() -> Void)?
        var drawnPathBinding: Binding<[CLLocationCoordinate2D]>?

        var drawMode = false
        var mapType: MKMapType = .standard
        var lastCameraRequest: CameraRequest?

        let pinState = LegacyPinUIState()
        var pinAnnotation: DragPinAnnotation?
        var spoofAnnotation: MKPointAnnotation?

        var routeOverlay: MKPolyline?
        var drawnOverlay: MKPolyline?
        var lastRouteCoords: [CLLocationCoordinate2D] = []
        var lastDrawnCoords: [CLLocationCoordinate2D] = []

        /// Swallow the map tap that follows an interaction with the pin menu.
        var suppressNextTapUntil = Date.distantPast

        func attach(map: MKMapView) {
            self.mapView = map
        }

        // MARK: Tap to place

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            guard Date() >= suppressNextTapUntil else { return }
            guard recognizer.state == .ended else { return }
            let point = recognizer.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)

            if drawMode {
                drawnPathBinding?.wrappedValue.append(coord)
            } else {
                session?.pin = coord
                onPinPlaced?()
            }
        }

        func didDragPin(to coordinate: CLLocationCoordinate2D) {
            session?.pin = coordinate
        }

        func suppressNextTap() {
            suppressNextTapUntil = Date().addingTimeInterval(0.15)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let pin = annotation as? DragPinAnnotation {
                let identifier = "locus.legacy.pin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKAnnotationView)
                    ?? MKAnnotationView(annotation: pin, reuseIdentifier: identifier)
                view.annotation = pin
                view.canShowCallout = false
                view.isDraggable = true
                view.centerOffset = CGPoint(x: 0, y: -26)

                // Reuse may carry stale hosted content — refresh it with the
                // live coordinator each time.
                view.subviews.filter { $0.tag == 727 }.forEach { $0.removeFromSuperview() }
                let hosting = UIHostingController(rootView: LegacyPinContent(state: pinState, coordinator: self))
                hosting.view.backgroundColor = .clear
                hosting.view.tag = 727
                view.addSubview(hosting.view)
                hosting.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    hosting.view.centerXAnchor.constraint(equalTo: view.centerXAnchor)
                ])
                return view
            }

            if annotation === spoofAnnotation {
                let identifier = "locus.legacy.spoof"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKAnnotationView)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false

                view.subviews.filter { $0.tag == 728 }.forEach { $0.removeFromSuperview() }
                let hosting = UIHostingController(rootView: LegacySpoofDot())
                hosting.view.backgroundColor = .clear
                hosting.view.tag = 728
                view.addSubview(hosting.view)
                hosting.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    hosting.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    hosting.view.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                if line === drawnOverlay {
                    renderer.strokeColor = UIColor(LocusTheme.accentSecondary)
                    renderer.lineWidth = 4
                    renderer.lineDashPattern = [6, 4]
                } else {
                    renderer.strokeColor = UIColor(LocusTheme.accent)
                    renderer.lineWidth = 5
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            switch newState {
            case .starting:
                pinState.selected = false
                pinState.isDragging = true
            case .dragging, .canceling:
                pinState.isDragging = true
            case .ending, .none:
                pinState.isDragging = false
                suppressNextTap()
            @unknown default:
                pinState.isDragging = false
            }
        }

        // MARK: Overlays

        /// CLLocationCoordinate2D isn't Equatable — compare elementwise.
        func sameCoords(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.latitude != y.latitude || x.longitude != y.longitude {
                return false
            }
            return true
        }

        func syncOverlays(map: MKMapView, routeCoords: [CLLocationCoordinate2D], drawnPath: [CLLocationCoordinate2D]) {
            if !sameCoords(routeCoords, lastRouteCoords) {
                if let routeOverlay {
                    map.removeOverlay(routeOverlay)
                    self.routeOverlay = nil
                }
                if routeCoords.count > 1 {
                    let line = MKPolyline(coordinates: routeCoords, count: routeCoords.count)
                    routeOverlay = line
                    map.addOverlay(line)
                }
                lastRouteCoords = routeCoords
            }
            if !sameCoords(drawnPath, lastDrawnCoords) {
                if let drawnOverlay {
                    map.removeOverlay(drawnOverlay)
                    self.drawnOverlay = nil
                }
                if drawnPath.count > 1 {
                    let line = MKPolyline(coordinates: drawnPath, count: drawnPath.count)
                    drawnOverlay = line
                    map.addOverlay(line)
                }
                lastDrawnCoords = drawnPath
            }
        }

        // MARK: UIGestureRecognizerDelegate — let pin content win its own taps

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // The map tap recognizer should ignore touches that begin inside an
            // annotation view (the hosted pin menu handles them itself).
            var current = touch.view
            while let node = current {
                if node is MKAnnotationView {
                    return false
                }
                current = node.superview
            }
            return true
        }
    }
}

/// SwiftUI pin content hosted inside the legacy annotation view.
private struct LegacyPinContent: View {
    @ObservedObject var state: LegacyPinUIState
    let coordinator: LegacyMapView.Coordinator

    var body: some View {
        MapDropPin(
            selected: state.selected,
            isDragging: state.isDragging,
            onSelect: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    state.selected.toggle()
                }
                coordinator.suppressNextTap()
            },
            onRemove: {
                withAnimation {
                    coordinator.session?.pin = nil
                    state.selected = false
                }
                coordinator.suppressNextTap()
            },
            // Long-press drag is driven by MKMapView's own annotation drag.
            onDragBegan: {},
            onDragMoved: { _ in },
            onDragEnded: {}
        )
    }
}

private struct LegacySpoofDot: View {
    var body: some View {
        ZStack {
            Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
            Circle().fill(LocusTheme.accent).frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
    }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet {
            completer.queryFragment = query
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
