import Foundation
import CoreGraphics
import UIKit

struct ShapeTemplate: Decodable {
    let id: String
    let displayName: String
    let category: String
    let symbolName: String
    let tintHex: String
    let keywords: [String]
    let paths: [[[Double]]]?

    var resolvedSymbolName: String {
        UIImage(systemName: symbolName) == nil ? "questionmark.circle.fill" : symbolName
    }

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

struct ShapeSuggestion: Identifiable {
    var id: String { shapeID }
    let shapeID: String
    let displayName: String
    let symbolName: String?
    let tintHex: String
    let confidence: Double
}

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

enum ShapeRasterizer {
    static func image(for template: ShapeTemplate, size: CGFloat, tintOverride: UIColor? = nil) -> UIImage {
        let renderSize = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: renderSize).image { rendererContext in
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .semibold)
            let fallback = UIImage(systemName: "questionmark.circle.fill", withConfiguration: configuration)!
            let symbol = UIImage(systemName: template.symbolName, withConfiguration: configuration) ?? fallback
            let tint = tintOverride ?? UIColor(hexString: template.tintHex)
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

enum ShapeMatcher {
    private static var contourCache: [String: [CGPoint]] = [:]

    static func suggestions(
        for strokes: [DrawingStroke],
        customShapes: [CustomShapeDefinition] = [],
        limit: Int = 3
    ) -> [ShapeSuggestion] {
        let rawDrawing = strokes.flatMap { $0.points.map(\.cgPoint) }
        guard rawDrawing.count >= 5 else { return [] }

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
            result = paths.flatMap { densifyClosed($0.compactMap(point(from:))) }
        } else {
            result = symbolContour(for: template)
        }
        contourCache[template.id] = result
        return result
    }

    private static func symbolContour(for template: ShapeTemplate) -> [CGPoint] {
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

        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < size, y >= 0, y < size else { return false }
            return pixels[(y * size + x) * 4 + 3] > 70
        }

        var result: [CGPoint] = []
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
        func oneWay(_ from: [CGPoint], _ to: [CGPoint]) -> Double {
            from.reduce(0) { sum, point in
                let nearest = to.lazy.map { hypot(point.x - $0.x, point.y - $0.y) }.min() ?? 1
                return sum + Double(nearest)
            } / Double(from.count)
        }
        return (oneWay(lhs, rhs) + oneWay(rhs, lhs)) / 2
    }
}

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
