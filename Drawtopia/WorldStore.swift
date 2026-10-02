import Foundation

@MainActor
final class WorldStore: ObservableObject {
    @Published var world: DrawtopiaWorld {
        didSet { save() }
    }

    private let saveKey = "drawtopia.saved.world.v1"
    private let customShapesKey = "drawtopia.custom.shapes.v1"
    @Published private(set) var customShapes: [CustomShapeDefinition] = []
    @Published var placementShapeID: String?

    init() {
        if let customData = UserDefaults.standard.data(forKey: customShapesKey),
           let savedShapes = try? JSONDecoder().decode([CustomShapeDefinition].self, from: customData) {
            customShapes = savedShapes
        }
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let saved = try? JSONDecoder().decode(DrawtopiaWorld.self, from: data) {
            world = saved
        } else {
            world = DrawtopiaWorld(
                items: [
                    WorldItem(shapeID: "tree", x: 0.22, y: 0.62, scale: 1.15),
                    WorldItem(shapeID: "house", x: 0.52, y: 0.58, scale: 1.25),
                    WorldItem(shapeID: "cloud", x: 0.72, y: 0.20, scale: 1.0)
                ]
            )
        }
    }

    func add(_ shapeID: String) {
        let offset = Double(world.items.count % 4) * 0.05
        world.items.append(WorldItem(shapeID: shapeID, x: 0.42 + offset, y: 0.48 + offset))
    }

    func chooseForPlacement(_ shapeID: String) {
        placementShapeID = shapeID
    }

    @discardableResult
    func addScenePage() -> Double {
        var updatedWorld = world
        updatedWorld.sceneWidth = min(max(updatedWorld.sceneWidth.rounded(.up) + 1, 2), 20)
        world = updatedWorld
        return updatedWorld.sceneWidth
    }

    @discardableResult
    func add(_ shapeID: String, at point: CGPoint) -> UUID {
        let item = WorldItem(
            shapeID: shapeID,
            x: min(max(point.x, 0.03), world.sceneWidth - 0.03),
            y: SceneLayout.constrainedY(for: shapeID, proposedY: point.y)
        )
        world.items.append(item)
        placementShapeID = nil
        return item.id
    }

    func deleteItem(_ id: UUID) {
        world.items.removeAll { $0.id == id }
    }

    func moveItem(_ id: UUID, to point: CGPoint) {
        guard let index = world.items.firstIndex(where: { $0.id == id }) else { return }
        var updatedWorld = world
        updatedWorld.items[index].x = min(max(point.x, 0.03), world.sceneWidth - 0.03)
        updatedWorld.items[index].y = SceneLayout.constrainedY(
            for: updatedWorld.items[index].shapeID,
            proposedY: point.y
        )
        world = updatedWorld
    }

    func bringItemToFront(_ id: UUID) {
        guard let index = world.items.firstIndex(where: { $0.id == id }) else { return }
        var updatedWorld = world
        let item = updatedWorld.items.remove(at: index)
        updatedWorld.items.append(item)
        world = updatedWorld
    }

    func addStroke(_ stroke: DrawingStroke) {
        guard stroke.points.count > 1 else { return }
        world.strokes.append(stroke)
    }

    func replaceStrokes(_ strokes: [DrawingStroke], with shapeID: String) {
        let ids = Set(strokes.map(\.id))
        let placement = ShapeMatcher.placement(for: strokes)
        world.strokes.removeAll { ids.contains($0.id) }
        world.items.append(
            WorldItem(
                shapeID: shapeID,
                x: min(max(placement.point.x, 0.05), world.sceneWidth - 0.05),
                y: SceneLayout.constrainedY(for: shapeID, proposedY: placement.point.y),
                scale: placement.scale
            )
        )
    }

    @discardableResult
    func saveCustomShape(name: String, from strokes: [DrawingStroke]) -> CustomShapeDefinition? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allPoints = strokes.flatMap(\.points)
        guard !cleanName.isEmpty, allPoints.count >= 5 else { return nil }

        let minX = allPoints.map(\.x).min() ?? 0
        let maxX = allPoints.map(\.x).max() ?? 1
        let minY = allPoints.map(\.y).min() ?? 0
        let maxY = allPoints.map(\.y).max() ?? 1
        let width = max(maxX - minX, 0.001)
        let height = max(maxY - minY, 0.001)
        let scale = max(width, height)
        let xPadding = (scale - width) / 2
        let yPadding = (scale - height) / 2
        let paths = strokes.map { stroke in
            stroke.points.map { point in
                NormalizedPoint(
                    x: (point.x - minX + xPadding) / scale,
                    y: (point.y - minY + yPadding) / scale
                )
            }
        }
        let shape = CustomShapeDefinition(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: cleanName,
            paths: paths,
            tintHex: strokes.last?.colorHex ?? "#6C4CF1",
            createdAt: Date()
        )
        customShapes.insert(shape, at: 0)
        persistCustomShapes()
        return shape
    }

    func deleteCustomShape(_ id: String) {
        customShapes.removeAll { $0.id == id }
        world.items.removeAll { $0.shapeID == id }
        persistCustomShapes()
    }

    func undoStroke() {
        guard !world.strokes.isEmpty else { return }
        world.strokes.removeLast()
    }

    func clear() {
        world = DrawtopiaWorld(
            name: world.name,
            terrain: world.terrain,
            weather: world.weather,
            sceneWidth: world.sceneWidth
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(world) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    private func persistCustomShapes() {
        guard let data = try? JSONEncoder().encode(customShapes) else { return }
        UserDefaults.standard.set(data, forKey: customShapesKey)
    }
}
