import Foundation
import SwiftUI

/// Complete serializable state of one child-created world.
///
/// Positions use world-normalized coordinates: `y` is always in the visible
/// 0...1 vertical range, while `x` may extend from 0 up to `sceneWidth`. This
/// allows the stage to grow horizontally without storing device-specific pixels.
struct DrawtopiaWorld: Codable {
    var name = "My First World"
    var terrain: Terrain = .meadow
    var weather: SceneWeather = .clear
    var sceneWidth: Double = 3
    var strokes: [DrawingStroke] = []
    var items: [WorldItem] = []

    /// Explicit keys support backward-compatible decoding as the world format grows.
    private enum CodingKeys: String, CodingKey {
        case name, terrain, weather, sceneWidth, strokes, items
    }

    init(
        name: String = "My First World",
        terrain: Terrain = .meadow,
        weather: SceneWeather = .clear,
        sceneWidth: Double = 3,
        strokes: [DrawingStroke] = [],
        items: [WorldItem] = []
    ) {
        self.name = name
        self.terrain = terrain
        self.weather = weather
        self.sceneWidth = sceneWidth
        self.strokes = strokes
        self.items = items
    }

    /// Loads old saves defensively. Missing fields receive modern defaults, so a
    /// world created before effects or horizontal expansion remains playable.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "My First World"
        terrain = try values.decodeIfPresent(Terrain.self, forKey: .terrain) ?? .meadow
        weather = try values.decodeIfPresent(SceneWeather.self, forKey: .weather) ?? .clear
        sceneWidth = max(try values.decodeIfPresent(Double.self, forKey: .sceneWidth) ?? 3, 1)
        strokes = try values.decodeIfPresent([DrawingStroke].self, forKey: .strokes) ?? []
        items = try values.decodeIfPresent([WorldItem].self, forKey: .items) ?? []
    }
}

/// Optional, mutually exclusive effect that is rendered only during Play mode.
enum SceneWeather: String, Codable, CaseIterable, Identifiable {
    case clear, rain, cloudy, windy, snow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clear: "No Effect"
        case .rain: "Raining"
        case .cloudy: "Cloudy"
        case .windy: "Windy"
        case .snow: "Snowing"
        }
    }
    var symbol: String {
        switch self {
        case .clear: "sparkles"
        case .rain: "cloud.rain.fill"
        case .cloudy: "cloud.fill"
        case .windy: "wind"
        case .snow: "cloud.snow.fill"
        }
    }
}

/// Base environment responsible for the palette and procedural terrain layers.
enum Terrain: String, Codable, CaseIterable, Identifiable {
    case meadow, desert, ocean, moon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meadow: "Meadow"
        case .desert: "Desert"
        case .ocean: "Ocean"
        case .moon: "Moon"
        }
    }

    var symbol: String {
        switch self {
        case .meadow: "leaf.fill"
        case .desert: "sun.max.fill"
        case .ocean: "water.waves"
        case .moon: "moon.stars.fill"
        }
    }

    /// Two-color palette used by SwiftUI previews and terrain-selection UI.
    var colors: [Color] {
        switch self {
        case .meadow: [Color(red: 0.55, green: 0.86, blue: 0.98), Color(red: 0.56, green: 0.82, blue: 0.42)]
        case .desert: [Color(red: 0.98, green: 0.72, blue: 0.42), Color(red: 0.91, green: 0.55, blue: 0.25)]
        case .ocean: [Color(red: 0.18, green: 0.73, blue: 0.91), Color(red: 0.05, green: 0.35, blue: 0.72)]
        case .moon: [Color(red: 0.17, green: 0.18, blue: 0.35), Color(red: 0.42, green: 0.42, blue: 0.58)]
        }
    }
}

/// Resolution-independent point used by drawings and custom vector shapes.
/// `x` can exceed 1 for content drawn on later horizontal scene pages.
struct NormalizedPoint: Codable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Converts a view-space point to normalized coordinates for persistence.
    init(_ point: CGPoint, in size: CGSize) {
        x = size.width > 0 ? point.x / size.width : 0
        y = size.height > 0 ? point.y / size.height : 0
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One uninterrupted finger or Pencil stroke drawn by the child.
struct DrawingStroke: Identifiable, Codable {
    var id = UUID()
    var points: [NormalizedPoint]
    var colorHex: String
    var width: Double
}

/// Reusable named shape learned from one or more of the child's own strokes.
/// Paths are normalized into a square so they can be rendered at any size.
struct CustomShapeDefinition: Identifiable, Codable {
    var id: String
    var name: String
    var paths: [[NormalizedPoint]]
    var tintHex: String
    var createdAt: Date
}

/// A catalog or custom shape placed in the horizontally scrolling world.
/// `shapeID` links to either `ShapeCatalog` or a `CustomShapeDefinition`.
struct WorldItem: Identifiable, Codable {
    var id = UUID()
    var shapeID: String
    var x: Double
    var y: Double
    var scale: Double = 1

    // `kind` is retained solely to migrate the earliest saved-world prototype.
    private enum CodingKeys: String, CodingKey { case id, shapeID, kind, x, y, scale }

    init(id: UUID = UUID(), shapeID: String, x: Double, y: Double, scale: Double = 1) {
        self.id = id
        self.shapeID = shapeID
        self.x = x
        self.y = y
        self.scale = scale
    }

    /// Decodes both the current `shapeID` field and the legacy `kind` field.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        shapeID = try values.decodeIfPresent(String.self, forKey: .shapeID)
            ?? values.decodeIfPresent(String.self, forKey: .kind)
            ?? "question"
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(shapeID, forKey: .shapeID)
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
        try values.encode(scale, forKey: .scale)
    }
}

/// Mutually exclusive gesture interpretation used by `WorldCanvasView`.
enum CreatorTool: String, CaseIterable, Identifiable {
    case draw, build, erase
    var id: String { rawValue }

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .draw: "paintbrush.fill"
        case .build: "hammer.fill"
        case .erase: "eraser.fill"
        }
    }
}

/// Central spatial policy shared by input handling and Metal rendering.
///
/// Keeping these rules outside the views is important: a prohibited object is
/// constrained when it is placed, dragged, loaded from an older save, and drawn.
/// The mountain interval is intentionally decorative and non-interactive.
enum SceneLayout {
    /// Semantic region in which a shape may be placed.
    enum PlacementZone {
        case sky, land, flexible
    }

    /// Safe center-point ranges leave room around large shapes at screen edges.
    static let skyRange = 0.08...0.45
    static let mountainRange = 0.46...0.64
    static let landRange = 0.68...0.92

    /// Boundary at which foreground terrain begins for each environment.
    static func groundLine(for terrain: Terrain) -> Double {
        switch terrain {
        case .meadow: 0.64
        case .desert: 0.61
        case .ocean: 0.90
        case .moon: 0.74
        }
    }

    /// Classifies a shape using explicit exceptions first and catalog categories
    /// second. Explicit lists handle cases such as birds that share an animal
    /// category with land-bound species.
    static func placementZone(for shapeID: String) -> PlacementZone {
        guard let shape = ShapeCatalog.byID[shapeID] else { return .flexible }
        let skyAnimals: Set<String> = ["bird", "owl", "eagle", "butterfly", "bee", "ladybug"]
        if skyAnimals.contains(shapeID) { return .sky }

        let skyObjects: Set<String> = ["cloud", "sun", "moon", "rain-cloud", "snow-cloud"]
        if skyObjects.contains(shapeID) { return .sky }

        let landCategories: Set<String> = [
            "Animals", "Wildlife", "Trees & Plants", "Buildings", "Home", "Vehicles", "People & Faces"
        ]
        if landCategories.contains(shape.category) { return .land }

        if shape.category == "Trees & Plants" { return .land }
        let terms = ([shape.displayName] + shape.keywords).map { $0.lowercased() }
        if terms.contains(where: { term in
            term.contains("tree") || term.contains("plant") || term.contains("flower") || term.contains("cactus")
        }) {
            return .land
        }

        return .flexible
    }

    /// Returns the nearest legal vertical coordinate for a shape.
    /// Flexible artwork may use Sky or Land, but is snapped across Mountains so
    /// no object can ever be left inside the backdrop-only band.
    static func constrainedY(for shapeID: String, proposedY: Double) -> Double {
        switch placementZone(for: shapeID) {
        case .sky:
            return min(max(proposedY, skyRange.lowerBound), skyRange.upperBound)
        case .land:
            return min(max(proposedY, landRange.lowerBound), landRange.upperBound)
        case .flexible:
            if mountainRange.contains(proposedY) {
                let skyDistance = abs(proposedY - skyRange.upperBound)
                let landDistance = abs(proposedY - landRange.lowerBound)
                return skyDistance < landDistance ? skyRange.upperBound : landRange.lowerBound
            }
            return min(max(proposedY, 0.04), 0.96)
        }
    }
}

extension Color {
    /// Creates a SwiftUI color from the catalog's six-digit RGB notation.
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
