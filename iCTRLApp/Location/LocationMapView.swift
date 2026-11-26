import MapKit
import SwiftUI

/// MKMapView for the location tab: tap to pick a target; shows the target,
/// the fake position, the walk still ahead and the favorites. The blue dot is
/// whatever iOS reports — with a fake location on, it sits on the fake point.
///
/// UIKit rather than SwiftUI's Map: tapping a point into a coordinate needs
/// iOS 17's MapReader there, and this app still runs on iOS 16.
struct LocationMapView: UIViewRepresentable {
    struct CenterRequest: Equatable {
        let id = UUID()
        let point: GeoPoint
        var zoomMeters: Double? = nil
    }

    var target: GeoPoint?
    var position: GeoPoint?
    var route: [GeoPoint]
    var favorites: [FavoritePlace]
    var follow: Bool
    var center: CenterRequest?
    var onTap: (GeoPoint) -> Void
    /// The person moved the map by hand (so stop following).
    var onUserPan: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .includingAll
        map.accessibilityLabel = "地圖"
        let start = center?.point ?? position ?? target ?? GeoPoint(25.033964, 121.564468)
        map.setRegion(MKCoordinateRegion(center: start.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200),
                      animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        // A double tap still zooms.
        let double = UITapGestureRecognizer(target: nil, action: nil)
        double.numberOfTapsRequired = 2
        map.addGestureRecognizer(double)
        tap.require(toFail: double)
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.sync(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LocationMapView
        private let targetPin = Pin(kind: .target)
        private let fakePin = Pin(kind: .fake)
        private var favoritePins: [UUID: Pin] = [:]
        private var line: MKPolyline?
        private var lineKey: [GeoPoint] = []
        private var lastCenter: UUID?
        private var lastFollowed: GeoPoint?

        init(_ parent: LocationMapView) { self.parent = parent }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let map = g.view as? MKMapView else { return }
            let point = g.location(in: map)
            // A tap on a pin selects the pin, not a new target.
            var hit = map.hitTest(point, with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
            let c = map.convert(point, toCoordinateFrom: map)
            parent.onTap(GeoPoint(c))
        }

        func sync(_ map: MKMapView) {
            place(targetPin, at: parent.target, on: map, title: "目標")
            place(fakePin, at: parent.position, on: map, title: "假定位")

            let wanted = Dictionary(uniqueKeysWithValues: parent.favorites.map { ($0.id, $0) })
            for (id, pin) in favoritePins where wanted[id] == nil {
                map.removeAnnotation(pin)
                favoritePins[id] = nil
            }
            for fav in parent.favorites {
                let pin: Pin
                if let existing = favoritePins[fav.id] {
                    pin = existing
                } else {
                    pin = Pin(kind: .favorite)
                    favoritePins[fav.id] = pin
                }
                place(pin, at: fav.point, on: map, title: fav.name)
            }

            // Redraw the walk only when it changes shape: points get consumed
            // from the front as it goes, and the head follows the fake pin.
            let key = Array(parent.route.dropFirst())
            if key != lineKey {
                if let line { map.removeOverlay(line) }
                line = nil
                lineKey = key
                if parent.route.count > 1 {
                    var coords = parent.route.map(\.coordinate)
                    let l = MKPolyline(coordinates: &coords, count: coords.count)
                    map.addOverlay(l)
                    line = l
                }
            }

            if let request = parent.center, request.id != lastCenter {
                lastCenter = request.id
                if let meters = request.zoomMeters {
                    map.setRegion(MKCoordinateRegion(center: request.point.coordinate, latitudinalMeters: meters,
                                                     longitudinalMeters: meters), animated: true)
                } else {
                    map.setCenter(request.point.coordinate, animated: true)
                }
            } else if parent.follow, let p = parent.position, p != lastFollowed {
                lastFollowed = p
                map.setCenter(p.coordinate, animated: true)
            }
        }

        private func place(_ pin: Pin, at point: GeoPoint?, on map: MKMapView, title: String) {
            pin.title = title
            guard let point else {
                if pin.onMap { map.removeAnnotation(pin); pin.onMap = false }
                return
            }
            pin.coordinate = point.coordinate
            pin.subtitle = point.text
            if !pin.onMap { map.addAnnotation(pin); pin.onMap = true }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // A gesture recognizer in a "began" state means a person is dragging.
            let touched = mapView.subviews.first?.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } ?? false
            if touched { DispatchQueue.main.async { self.parent.onUserPan() } }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? Pin else { return nil }
            let id = "pin-\(pin.kind)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
            view.annotation = pin
            view.canShowCallout = true
            switch pin.kind {
            case .target:
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "mappin")
                view.displayPriority = .required
            case .fake:
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "location.fill")
                view.displayPriority = .required
            case .favorite:
                view.markerTintColor = .systemYellow
                view.glyphImage = UIImage(systemName: "star.fill")
                view.displayPriority = .defaultHigh
            }
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = .systemBlue
            r.lineWidth = 4
            r.lineDashPattern = [6, 4]
            return r
        }
    }

    final class Pin: NSObject, MKAnnotation {
        enum Kind { case target, fake, favorite }
        let kind: Kind
        @objc dynamic var coordinate = CLLocationCoordinate2D()
        var title: String?
        var subtitle: String?
        var onMap = false
        init(kind: Kind) { self.kind = kind }
    }
}

/// A thumb pad: drag from the middle; how far is how fast. Reports dx east,
/// dy north in -1...1, and (0, 0) on release.
struct JoystickPad: View {
    var onChange: (Double, Double) -> Void
    @State private var knob: CGSize = .zero
    @State private var lastSent = Date.distantPast
    private let radius: CGFloat = 56

    init(onChange: @escaping (Double, Double) -> Void) {
        self.onChange = onChange
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                .frame(width: radius * 2 + 24, height: radius * 2 + 24)
            ForEach(0..<4) { i in
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .offset(y: -(radius + 2))
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: 52, height: 52)
                .shadow(radius: 3)
                .offset(knob)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var v = value.translation
                    let len = sqrt(v.width * v.width + v.height * v.height)
                    if len > radius { v = CGSize(width: v.width / len * radius, height: v.height / len * radius) }
                    knob = v
                    // A drag fires every frame; the simulator only needs a few a second.
                    if Date().timeIntervalSince(lastSent) > 0.1 {
                        lastSent = Date()
                        onChange(Double(v.width / radius), Double(-v.height / radius))
                    }
                }
                .onEnded { _ in
                    knob = .zero
                    lastSent = .distantPast
                    onChange(0, 0)
                }
        )
        .accessibilityLabel("搖桿圓盤")
    }
}
