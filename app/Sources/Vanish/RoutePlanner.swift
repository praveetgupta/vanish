import Foundation
import MapKit

enum TravelMode: String, CaseIterable, Identifiable {
    case drive = "Drive"
    case walk = "Walk"
    case cycle = "Cycle"
    var id: String { rawValue }

    /// realistic sustained speeds in m/s
    var speed: Double {
        switch self {
        case .drive: return 11.5
        case .walk: return 1.4
        case .cycle: return 4.7
        }
    }
}

enum RoutePlanner {
    /// Fetch a real route via Apple Maps directions and convert it to a timed
    /// waypoint list for the engine. Falls back to a straight line when no
    /// route exists (e.g. walking across an ocean).
    static func plan(from source: CLLocationCoordinate2D,
                     to destination: CLLocationCoordinate2D,
                     mode: TravelMode) async -> [RoutePoint] {
        do {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = mode == .drive ? .automobile : (mode == .walk ? .walking : .any)
            request.requestsAlternateRoutes = false
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first {
                return interpolate(polyline: route.polyline, speed: mode.speed)
            }
        } catch {
            // fall through to straight-line fallback
        }
        return interpolate(polyline: MKPolyline(coordinates: [source, destination], count: 2),
                           speed: mode.speed)
    }

    /// Walk the polyline emitting one point per ~speed·tick meters with human
    /// wobble: speed noise per tick and a few meters of GPS jitter.
    static func interpolate(polyline: MKPolyline, speed: Double, tick: Double = 1.0) -> [RoutePoint] {
        let coords = polyline.coordinates
        guard coords.count >= 2 else { return [] }

        var out: [RoutePoint] = [RoutePoint(lat: coords[0].latitude, lon: coords[0].longitude, delayMs: 0)]
        let step = speed * tick
        var pending = step

        for (a, b) in zip(coords, coords.dropFirst()) {
            let segmentLength = haversine(a, b)
            var covered = 0.0
            while covered + pending <= segmentLength, segmentLength > 0 {
                covered += pending
                let fraction = covered / segmentLength
                let lat = a.latitude + (b.latitude - a.latitude) * fraction
                let lon = a.longitude + (b.longitude - a.longitude) * fraction
                out.append(RoutePoint(
                    lat: lat + wobble,
                    lon: lon + wobble,
                    delayMs: tick * 1000 * Double.random(in: 0.9...1.15)
                ))
                pending = step * Double.random(in: 0.85...1.15)
            }
            pending -= (segmentLength - covered)
        }
        return out
    }

    private static var wobble: Double { Double.random(in: -0.00006...0.00006) }

    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(sqrt(h), 1))
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
