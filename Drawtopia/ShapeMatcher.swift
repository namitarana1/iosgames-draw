import Foundation
import CoreGraphics
import UIKit

/// One built-in shape decoded from `ShapeCatalog.json`.
///
/// Shapes may provide explicit polygon paths for distinct silhouettes or rely on an SF Symbol.
/// Recognition keywords are intentionally data-only so the catalog can grow without recompiling
/// matching logic or user-interface code.
struct ShapeTemplate: Decodable {
    let id: String
    let displayName: String
    let category: String
    let symbolName: String
    let tintHex: String
    let keywords: [String]
    let paths: [[[Double]]]?

    var resolvedSymbolName: String {
        // Catalog mistakes degrade to an obvious placeholder instead of producing a blank object.
        UIImage(systemName: symbolName) == nil ? "questionmark.circle.fill" : symbolName
    }

    /// Validates loosely typed JSON coordinate pairs and exposes Core Graphics points to callers.
    var vectorPaths: [[CGPoint]]? {
        guard let paths, !paths.isEmpty else { return nil }
        let converted = paths.map { path in
            path.compactMap { pair -> CGPoint? in
                guard pair.count == 2 else { return nil }
                return CGPoint(x: pair[0], y: pair[1])
            }
        }.filter { $0.count >= 3 }
        return converted.isEmpty ? nil : converted
    }
}

/// A display-ready recognition result. Confidence is advisory; the child still chooses the result.
struct ShapeSuggestion: Identifiable {
    var id: String { shapeID }
    let shapeID: String
    let displayName: String
    let symbolName: String?
    let tintHex: String
    let confidence: Double
}

/// Lazily loaded, immutable indexes over the bundled catalog.
enum ShapeCatalog {
    static let templates: [ShapeTemplate] = {
        guard let url = Bundle.main.url(forResource: "ShapeCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([ShapeTemplate].self, from: data) else {
            return []
        }
        return result
    }()

    static let byID: [String: ShapeTemplate] = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
}

/// Produces bitmap versions of SF Symbol-backed catalog entries for both Metal and SwiftUI.
enum ShapeRasterizer {
    static func image(for template: ShapeTemplate, size: CGFloat, tintOverride: UIColor? = nil) -> UIImage {
        let renderSize = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: renderSize).image { rendererContext in
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .semibold)
            let fallback = UIImage(systemName: "questionmark.circle.fill", withConfiguration: configuration)!
            let symbol = UIImage(systemName: template.symbolName, withConfiguration: configuration) ?? fallback
            let tint = tintOverride ?? UIColor(hexString: template.tintHex)
            // When multiple catalog concepts share one system glyph, apply a stable geometric
            // variant. This keeps their silhouettes observably different rather than changing
            // color alone, while explicit vector entries retain their authored geometry.
            let variant = geometryVariant(for: template)
            let context = rendererContext.cgContext

            context.saveGState()
            context.translateBy(x: size / 2, y: size / 2)
            context.rotate(by: variant.rotation)
            context.scaleBy(x: variant.mirrored ? -variant.scaleX : variant.scaleX, y: variant.scaleY)
            context.translateBy(x: -size / 2, y: -size / 2)
            symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: size * 0.10, y: size * 0.10, width: size * 0.80, height: size * 0.80))
            context.restoreGState()

        }
    }

    private static func geometryVariant(for template: ShapeTemplate) -> GeometryVariant {
        // Sorting by id makes transformations deterministic across app launches and devices.
        let duplicates = ShapeCatalog.templates
            .filter { $0.symbolName == template.symbolName && $0.vectorPaths == nil }
            .sorted { $0.id < $1.id }
        guard duplicates.count > 1,
              let ordinal = duplicates.firstIndex(where: { $0.id == template.id }) else {
            return GeometryVariant()
        }

        let signedStep = CGFloat(ordinal) - CGFloat(duplicates.count - 1) / 2
        return GeometryVariant(
            scaleX: 1 + signedStep * 0.045,
            scaleY: 1 - signedStep * 0.025,
            rotation: signedStep * .pi / 90,
            mirrored: ordinal.isMultiple(of: 2) && !template.symbolName.contains("arrow")
        )
    }

    private struct GeometryVariant {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: CGFloat = 0
        var mirrored = false
    }
}

/// A small, on-device contour matcher; no drawing or child data leaves the device.
///
/// It is intentionally tolerant of translation, scale, direction, and sampling speed. Rotation is
/// retained because orientation is meaningful for objects such as a vertical tree or horizontal
/// car. Aspect ratio and stroke count provide gentle tie-breakers rather than hard requirements.
enum ShapeMatcher {
    /// Raster contours are moderately expensive to extract, so compute each catalog entry once.
    private static var contourCache: [String: [CGPoint]] = [:]

    /// Returns the lowest-distance catalog/custom candidates, best match first.
    static func suggestions(
        for strokes: [DrawingStroke],
        customShapes: [CustomShapeDefinition] = [],
        limit: Int = 3
    ) -> [ShapeSuggestion] {
        let rawDrawing = strokes.flatMap { $0.points.map(\.cgPoint) }
        guard rawDrawing.count >= 5 else { return [] }

        // Center and uniformly scale before comparison; uniform scaling preserves aspect ratio.
        let drawing = normalize(rawDrawing)
        let drawingAspect = aspectRatio(rawDrawing)

        let catalogMatches: [(ShapeSuggestion, Double)] = ShapeCatalog.templates.map { template in
            let templatePoints = points(for: template)
            let rawScore = score(
                drawing: drawing,
                drawingAspect: drawingAspect,
                drawingStrokeCount: strokes.count,
                candidatePoints: templatePoints,
                candidateStrokeCount: template.paths?.count ?? 1
            )
            // A tiny preference for authored contours compensates for noise introduced by sampling
            // rasterized system symbols. It is far too small to overpower an actual close match.
            let total = max(0, rawScore - (template.paths == nil ? 0 : 0.025))
            let confidence = max(0.18, min(0.98, 1 - total / 0.58))
            return (
                ShapeSuggestion(
                    shapeID: template.id,
                    displayName: template.displayName,
                    symbolName: template.symbolName,
                    tintHex: template.tintHex,
                    confidence: confidence
                ),
                total
            )
        }

        let customMatches: [(ShapeSuggestion, Double)] = customShapes.map { custom in
            let candidatePoints = custom.paths.flatMap { $0.map(\.cgPoint) }
            let rawScore = score(
                drawing: drawing,
                drawingAspect: drawingAspect,
                drawingStrokeCount: strokes.count,
                candidatePoints: candidatePoints,
                candidateStrokeCount: custom.paths.count
            )
            let total = max(0, rawScore - 0.025)
            let confidence = max(0.18, min(0.98, 1 - total / 0.58))
            return (
                ShapeSuggestion(
                    shapeID: custom.id,
                    displayName: custom.name,
                    symbolName: nil,
                    tintHex: custom.tintHex,
                    confidence: confidence
                ),
                total
            )
        }

        return (catalogMatches + customMatches)
        .sorted { $0.1 < $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    private static func score(
        drawing: [CGPoint],
        drawingAspect: Double,
        drawingStrokeCount: Int,
        candidatePoints: [CGPoint],
        candidateStrokeCount: Int
    ) -> Double {
        // Symmetric Chamfer distance measures silhouette similarity without requiring corresponding
        // point counts. Log aspect error treats a 2:1 vs 1:1 mismatch like 1:2 vs 1:1.
        let shapeDistance = chamferDistance(drawing, normalize(candidatePoints))
        let candidateAspect = aspectRatio(candidatePoints)
        let aspectPenalty = abs(log(max(drawingAspect, 0.05) / max(candidateAspect, 0.05))) * 0.07
        let strokePenalty = min(Double(abs(drawingStrokeCount - candidateStrokeCount)) * 0.006, 0.09)
        return shapeDistance + aspectPenalty + strokePenalty
    }

    private static func points(for template: ShapeTemplate) -> [CGPoint] {
        if let cached = contourCache[template.id] { return cached }
        let result: [CGPoint]
        if let paths = template.paths, !paths.isEmpty {
            // Densification prevents a polygon with few vertices from receiving an unfair score
            // against a finger stroke that naturally contains dozens of sampled points.
            result = paths.flatMap { densifyClosed($0.compactMap(point(from:))) }
        } else {
            result = symbolContour(for: template)
        }
        contourCache[template.id] = result
        return result
    }

    private static func symbolContour(for template: ShapeTemplate) -> [CGPoint] {
        // Render at a fixed small resolution, then keep boundary pixels only. Interior pixels would
        // overweight filled shapes and make the score depend on area rather than outline.
        let size = 64
        let image = ShapeRasterizer.image(for: template, size: CGFloat(size), tintOverride: .black)
        guard let cgImage = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        /// Safely samples alpha; coordinates outside the image are considered transparent.
        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < size, y >= 0, y < size else { return false }
            return pixels[(y * size + x) * 4 + 3] > 70
        }

        var result: [CGPoint] = []
        // A two-pixel stride is a useful accuracy/performance balance for a live suggestion UI.
        for y in stride(from: 1, to: size - 1, by: 2) {
            for x in stride(from: 1, to: size - 1, by: 2) where opaque(x, y) {
                if !opaque(x - 2, y) || !opaque(x + 2, y) || !opaque(x, y - 2) || !opaque(x, y + 2) {
                    result.append(CGPoint(x: Double(x) / Double(size), y: Double(y) / Double(size)))
                }
            }
        }
        return result
    }

    static func placement(for strokes: [DrawingStroke]) -> (point: CGPoint, scale: Double) {
        // Replacement objects inherit the drawing's center and a bounded scale derived from its
        // largest dimension. The multiplier maps unit-world drawing size to catalog object size.
        let points = strokes.flatMap { $0.points.map(\.cgPoint) }
        guard let first = points.first else { return (CGPoint(x: 0.5, y: 0.5), 1) }
        let bounds = points.dropFirst().reduce(
            (minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        ) { bounds, point in
            (min(bounds.minX, point.x), max(bounds.maxX, point.x), min(bounds.minY, point.y), max(bounds.maxY, point.y))
        }
        let span = max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
        return (
            CGPoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2),
            min(max(span * 5.5, 0.65), 2.4)
        )
    }

    private static func point(from pair: [Double]) -> CGPoint? {
        guard pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    private static func densify(_ points: [CGPoint]) -> [CGPoint] {
        // Ten evenly spaced samples per segment make comparison independent of vertex spacing.
        guard points.count > 1 else { return points }
        return zip(points, points.dropFirst()).flatMap { start, end in
            (0..<10).map { step in
                let t = CGFloat(step) / 10
                return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            }
        } + [points.last!]
    }

    private static func densifyClosed(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first, points.count > 2 else { return densify(points) }
        return densify(points + [first])
    }

    private static func normalize(_ points: [CGPoint]) -> [CGPoint] {
        // Uniform scaling around the bounds center removes location and size but not proportions.
        guard let first = points.first else { return [] }
        let bounds = points.dropFirst().reduce(
            (minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        ) { bounds, point in
            (min(bounds.minX, point.x), max(bounds.maxX, point.x), min(bounds.minY, point.y), max(bounds.maxY, point.y))
        }
        let width = max(bounds.maxX - bounds.minX, 0.001)
        let height = max(bounds.maxY - bounds.minY, 0.001)
        let scale = max(width, height)
        let center = CGPoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2)
        return points.map { CGPoint(x: ($0.x - center.x) / scale, y: ($0.y - center.y) / scale) }
    }

    private static func aspectRatio(_ points: [CGPoint]) -> Double {
        guard let first = points.first else { return 1 }
        let bounds = points.dropFirst().reduce(
            (minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        ) { bounds, point in
            (min(bounds.minX, point.x), max(bounds.maxX, point.x), min(bounds.minY, point.y), max(bounds.maxY, point.y))
        }
        return Double(max(bounds.maxX - bounds.minX, 0.001) / max(bounds.maxY - bounds.minY, 0.001))
    }

    private static func chamferDistance(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 1 }
        // Compute both directions: a one-way measure could call a tiny subset a perfect match for a
        // much more complex outline simply because every subset point is near the larger shape.
        func oneWay(_ from: [CGPoint], _ to: [CGPoint]) -> Double {
            from.reduce(0) { sum, point in
                let nearest = to.lazy.map { hypot(point.x - $0.x, point.y - $0.y) }.min() ?? 1
                return sum + Double(nearest)
            } / Double(from.count)
        }
        return (oneWay(lhs, rhs) + oneWay(rhs, lhs)) / 2
    }
}

/// UIKit color parsing used by the rasterizer; SwiftUI and Metal have parallel lightweight helpers.
private extension UIColor {
    convenience init(hexString: String) {
        let value = UInt64(hexString.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
