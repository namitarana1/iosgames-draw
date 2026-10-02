import Foundation
import SwiftUI

struct DrawtopiaWorld: Codable {
    var name = "My First World"
    var terrain: Terrain = .meadow
    var weather: SceneWeather = .clear
    var sceneWidth: Double = 3
    var strokes: [DrawingStroke] = []
    var items: [WorldItem] = []

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

    var colors: [Color] {
        switch self {
        case .meadow: [Color(red: 0.55, green: 0.86, blue: 0.98), Color(red: 0.56, green: 0.82, blue: 0.42)]
        case .desert: [Color(red: 0.98, green: 0.72, blue: 0.42), Color(red: 0.91, green: 0.55, blue: 0.25)]
        case .ocean: [Color(red: 0.18, green: 0.73, blue: 0.91), Color(red: 0.05, green: 0.35, blue: 0.72)]
        case .moon: [Color(red: 0.17, green: 0.18, blue: 0.35), Color(red: 0.42, green: 0.42, blue: 0.58)]
        }
    }
}

struct NormalizedPoint: Codable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint, in size: CGSize) {
        x = size.width > 0 ? point.x / size.width : 0
        y = size.height > 0 ? point.y / size.height : 0
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct DrawingStroke: Identifiable, Codable {
    var id = UUID()
    var points: [NormalizedPoint]
    var colorHex: String
    var width: Double
}

struct CustomShapeDefinition: Identifiable, Codable {
    var id: String
    var name: String
    var paths: [[NormalizedPoint]]
    var tintHex: String
    var createdAt: Date
}

struct WorldItem: Identifiable, Codable {
    var id = UUID()
    var shapeID: String
    var x: Double
    var y: Double
    var scale: Double = 1

    private enum CodingKeys: String, CodingKey { case id, shapeID, kind, x, y, scale }

    init(id: UUID = UUID(), shapeID: String, x: Double, y: Double, scale: Double = 1) {
        self.id = id
        self.shapeID = shapeID
        self.x = x
        self.y = y
        self.scale = scale
    }

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

enum SceneLayout {
    enum PlacementZone {
        case sky, land, flexible
    }

    static let skyRange = 0.08...0.45
    static let mountainRange = 0.46...0.64
    static let landRange = 0.68...0.92

    static func groundLine(for terrain: Terrain) -> Double {
        switch terrain {
        case .meadow: 0.64
        case .desert: 0.61
        case .ocean: 0.90
        case .moon: 0.74
        }
    }

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
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
