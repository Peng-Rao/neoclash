import CoreLocation
import MapKit
import NeoClashCore
import SwiftUI
import simd

// MARK: - Model

private struct MapNode: Identifiable {
    let id = UUID()
    var coord: SIMD2<Double>            // (longitude, latitude)
    var label: String
    var weight: Int
    var clCoordinate: CLLocationCoordinate2D { .init(latitude: coord.y, longitude: coord.x) }
}

enum MapTimeRange: String, CaseIterable, Identifiable {
    case live, today, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

// MARK: - Map view

/// Labs: a live world map of active proxy flows, drawn on a native MapKit base with animated
/// connection arcs from the local machine to each geolocated proxy node.
struct MapView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var range: MapTimeRange = .live
    @State private var camera: MapCameraPosition = .region(MapView.localRegion())
    @State private var framedSignature = ""

    /// A region centred on the local machine, used until live connections widen the view so the
    /// "Local" origin point is always on screen.
    static func localRegion() -> MKCoordinateRegion {
        let local = GeoLocator.localCoordinate()
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: local.y, longitude: local.x),
            span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 70)
        )
    }

    var body: some View {
        let local = GeoLocator.localCoordinate()
        let nodes = nodeList
        let signature = mapSignature(nodes)

        VStack(spacing: 0) {
            header
            mapArea(local: local, nodes: nodes)
        }
        .navigationTitle("Map")
        .onAppear { reframe(local: local, nodes: nodes, signature: signature) }
        .onChange(of: signature) { _, new in reframe(local: local, nodes: nodes, signature: new) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Map", systemImage: "map")
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Badge(kind: .accent, text: "Experimental")
            Spacer(minLength: 12)
            Picker("Range", selection: $range) {
                ForEach(MapTimeRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Map

    private func mapArea(local: SIMD2<Double>, nodes: [MapNode]) -> some View {
        let localCL = CLLocationCoordinate2D(latitude: local.y, longitude: local.x)
        let maxWeight = nodes.first?.weight ?? 1

        return MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                Annotation("Local", coordinate: localCL, anchor: .center) {
                    MapMarkerDot(color: .accentColor, emphatic: true)
                }
                ForEach(nodes) { node in
                    Annotation(node.label, coordinate: node.clCoordinate, anchor: .center) {
                        MapMarkerDot(color: .ncViolet, emphatic: false)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls {}
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, _ in
                        drawArcs(
                            context,
                            proxy: proxy,
                            localCL: localCL,
                            nodes: nodes,
                            maxWeight: maxWeight,
                            phase: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if nodes.isEmpty { emptyHint }
            }
        }
        .clipShape(.rect(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var emptyHint: some View {
        Text(runtime.status.isRunning ? "No active proxied connections" : "Start the core to map active connections")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(.bottom, 14)
    }

    // MARK: Arc drawing (screen-space overlay aligned to the live map projection)

    private func drawArcs(
        _ context: GraphicsContext,
        proxy: MapProxy,
        localCL: CLLocationCoordinate2D,
        nodes: [MapNode],
        maxWeight: Int,
        phase: TimeInterval
    ) {
        guard let a = proxy.convert(localCL, to: .local) else { return }
        for node in nodes {
            guard let b = proxy.convert(node.clCoordinate, to: .local) else { continue }
            let len = max(1, hypot(b.x - a.x, b.y - a.y))
            let intensity = 0.45 + 0.55 * (Double(node.weight) / Double(max(1, maxWeight)))
            let baseBulge = len * 0.22

            // Feathered ribbon: strands share endpoints and fan out at the midpoint.
            let strands = 4 + min(12, node.weight)
            for i in 0..<strands {
                let f = strands == 1 ? 0 : (Double(i) / Double(strands - 1)) * 2 - 1   // -1...1
                var path = Path()
                path.move(to: a)
                path.addQuadCurve(to: b, control: arcControl(a, b, bulge: baseBulge * (1 + f * 0.55)))
                context.stroke(
                    path,
                    with: .color(.ncViolet.opacity(0.10 + 0.35 * (1 - abs(f)) * intensity)),
                    lineWidth: 0.9
                )
            }

            // Flowing particles along the centre curve.
            let control = arcControl(a, b, bulge: baseBulge)
            let particles = 3
            for k in 0..<particles {
                let t = (phase / 2.4 + Double(k) / Double(particles)).truncatingRemainder(dividingBy: 1)
                let p = quadPoint(a, control, b, CGFloat(t))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4.8, y: p.y - 4.8, width: 9.6, height: 9.6)),
                             with: .color(.ncViolet.opacity(0.18)))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)),
                             with: .color(.ncViolet.opacity(0.95)))
            }
        }
    }

    private func arcControl(_ a: CGPoint, _ b: CGPoint, bulge: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        var nx = -dy / len, ny = dx / len
        if ny > 0 { nx = -nx; ny = -ny }     // bias the bulge upward
        return CGPoint(x: mid.x + nx * bulge, y: mid.y + ny * bulge)
    }

    private func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
            y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y
        )
    }

    // MARK: Data

    private var nodeList: [MapNode] {
        guard runtime.status.isRunning else { return [] }
        let egress = runtime.networkStatus.egressCountryCode
        var byLabel: [String: MapNode] = [:]
        for conn in runtime.connections {
            guard let resolved = GeoLocator.resolveChain(conn.chain, egressCode: egress) else { continue }
            if var existing = byLabel[resolved.label] {
                existing.weight += 1
                byLabel[resolved.label] = existing
            } else {
                byLabel[resolved.label] = MapNode(coord: resolved.coordinate, label: resolved.label, weight: 1)
            }
        }
        return byLabel.values.sorted { $0.weight > $1.weight }
    }

    private func mapSignature(_ nodes: [MapNode]) -> String {
        nodes.isEmpty ? "empty" : nodes.map(\.label).sorted().joined(separator: "|")
    }

    private func reframe(local: SIMD2<Double>, nodes: [MapNode], signature: String) {
        guard signature != framedSignature else { return }
        framedSignature = signature
        let region = nodes.isEmpty ? Self.localRegion() : fitRegion(local: local, nodes: nodes)
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(region)
        }
    }

    private func fitRegion(local: SIMD2<Double>, nodes: [MapNode]) -> MKCoordinateRegion {
        let points = [local] + nodes.map(\.coord)
        let lons = points.map(\.x), lats = points.map(\.y)
        let minLon = lons.min() ?? 100, maxLon = lons.max() ?? 120
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 40
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: min(max((maxLat - minLat) * 1.8, 24), 150),
            longitudeDelta: min(max((maxLon - minLon) * 1.8, 28), 330)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Annotation marker

private struct MapMarkerDot: View {
    var color: Color
    var emphatic: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: emphatic ? 22 : 18, height: emphatic ? 22 : 18)
            Circle().stroke(color, lineWidth: 1.8).frame(width: emphatic ? 11 : 9, height: emphatic ? 11 : 9)
            Circle().fill(.white).frame(width: 3.6, height: 3.6)
        }
        .shadow(color: color.opacity(0.4), radius: 4)
    }
}
