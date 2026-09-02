import SwiftUI
import MapKit

/// MapKit-backed map: click to drop a pin, shows the spoofed position and the
/// planned route as a polyline.
struct VanishMapView: NSViewRepresentable {
    @Binding var pin: CLLocationCoordinate2D?
    var fake: CLLocationCoordinate2D?
    var preview: [CLLocationCoordinate2D]
    var follow: Bool
    var onTap: (CLLocationCoordinate2D) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self

        // pin
        let pinAnnotations = map.annotations.compactMap { $0 as? PinAnnotation }
        if let pin {
            if let existing = pinAnnotations.first {
                existing.coordinate = pin
            } else {
                map.addAnnotation(PinAnnotation(coordinate: pin))
            }
        } else if !pinAnnotations.isEmpty {
            map.removeAnnotations(pinAnnotations)
        }

        // spoofed position
        let fakeAnnotations = map.annotations.compactMap { $0 as? FakeAnnotation }
        if let fake {
            if let existing = fakeAnnotations.first {
                existing.coordinate = fake
            } else {
                map.addAnnotation(FakeAnnotation(coordinate: fake))
            }
            if follow, !context.coordinator.isSameSpot(fake) {
                if context.coordinator.lastCentered == nil {
                    // First fix of a session: the map is still at whatever span
                    // it opened with (the whole world), so centering alone would
                    // leave the dot a speck. Zoom in once, then never again —
                    // after this the user's own zoom is preserved.
                    map.setRegion(MKCoordinateRegion(center: fake,
                                                     latitudinalMeters: 2_000,
                                                     longitudinalMeters: 2_000),
                                  animated: true)
                } else {
                    map.setCenter(fake, animated: true)
                }
                context.coordinator.lastCentered = fake
            }
        } else if !fakeAnnotations.isEmpty {
            map.removeAnnotations(fakeAnnotations)
            context.coordinator.lastCentered = nil
        }

        // route preview overlay
        if preview.count >= 2 {
            if context.coordinator.previewCount != preview.count {
                if let old = context.coordinator.previewPolyline {
                    map.removeOverlay(old)
                }
                let line = MKPolyline(coordinates: preview, count: preview.count)
                map.addOverlay(line)
                context.coordinator.previewPolyline = line
                context.coordinator.previewCount = preview.count
                map.setVisibleMapRect(line.boundingMapRect,
                                      edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                                      animated: true)
            }
        } else if let old = context.coordinator.previewPolyline {
            map.removeOverlay(old)
            context.coordinator.previewPolyline = nil
            context.coordinator.previewCount = 0
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: VanishMapView
        var previewPolyline: MKPolyline?
        var previewCount = 0
        var lastCentered: CLLocationCoordinate2D?

        init(parent: VanishMapView) { self.parent = parent }

        /// The spoofed-position puck: a green core inside a white ring with a
        /// soft halo, drawn rather than taken from SF Symbols — a template
        /// symbol renders near-black and tiny here, which is invisible against
        /// the dark map.
        static let puck: NSImage = {
            let size = NSSize(width: 44, height: 44)
            let image = NSImage(size: size)
            image.lockFocus()
            let center = NSPoint(x: size.width / 2, y: size.height / 2)

            func circle(radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
            }

            NSColor.systemGreen.withAlphaComponent(0.22).setFill()
            circle(radius: 21).fill()

            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            circle(radius: 14).fill()

            NSColor.white.setFill()
            circle(radius: 9).fill()

            NSColor.systemGreen.setFill()
            circle(radius: 6.5).fill()

            image.unlockFocus()
            return image
        }()

        func isSameSpot(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard let last = lastCentered else { return false }
            return abs(last.latitude - coordinate.latitude) < 2e-6
                && abs(last.longitude - coordinate.longitude) < 2e-6
        }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            parent.onTap(map.convert(point, toCoordinateFrom: map))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85)
                renderer.lineWidth = 3.5
                renderer.lineDashPattern = [2, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is PinAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "vanish.pin")
                            as? MKMarkerAnnotationView) ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "vanish.pin")
                view.annotation = annotation
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: "target pin")
                view.isDraggable = false
                view.canShowCallout = false
                return view
            }
            if annotation is FakeAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "vanish.fake")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "vanish.fake")
                view.annotation = annotation
                view.image = Coordinator.puck
                view.centerOffset = .zero
                view.canShowCallout = false
                return view
            }
            return nil
        }
    }
}

final class PinAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

final class FakeAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}
