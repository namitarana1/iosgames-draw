import Foundation

/// The single source of truth for the world currently being edited.
///
/// Keeping mutations here gives every screen the same placement rules and makes persistence
/// automatic. The type is main-actor isolated because SwiftUI publishes its values on the UI
/// thread and because a drag gesture can generate many mutations in quick succession.
@MainActor
final class WorldStore: ObservableObject {
    /// Assigning a new value persists a complete, internally consistent world snapshot.
    /// Several methods deliberately mutate a local copy and assign it back so this observer is
    /// guaranteed to run even when a nested array element changes.
    @Published var world: DrawtopiaWorld {
        didSet { save() }
    }

    // The version suffix leaves room for a future migration without overwriting older data.
    private let saveKey = "drawtopia.saved.world.v1"
    private let customShapesKey = "drawtopia.custom.shapes.v1"

    /// User-created symbols live separately from a world so they remain available after Clear.
    @Published private(set) var customShapes: [CustomShapeDefinition] = []

    /// A transient selection used by Build mode. It is intentionally not part of the saved world.
    @Published var placementShapeID: String?

    /// Restores both libraries before constructing the UI. Corrupt or missing data falls back to
    /// a small starter scene, so an interrupted write can never prevent Drawtopia from opening.
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

    /// Convenience insertion used by older UI paths. New touch placement should use `add(_:at:)`.
    func add(_ shapeID: String) {
        let offset = Double(world.items.count % 4) * 0.05
        world.items.append(WorldItem(shapeID: shapeID, x: 0.42 + offset, y: 0.48 + offset))
    }

    /// Arms a library shape for the next tap in the scene.
    func chooseForPlacement(_ shapeID: String) {
        placementShapeID = shapeID
    }

    @discardableResult
    /// Extends the world by one viewport, up to a practical limit of twenty pages.
    /// The returned width lets the canvas immediately scroll to the newly created page.
    func addScenePage() -> Double {
        var updatedWorld = world
        updatedWorld.sceneWidth = min(max(updatedWorld.sceneWidth.rounded(.up) + 1, 2), 20)
        world = updatedWorld
        return updatedWorld.sceneWidth
    }

    @discardableResult
    /// Places an object at world coordinates, respecting horizontal edges and its semantic zone.
    /// Birds and clouds are constrained to sky, while plants and land animals are grounded.
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

    /// Removes one placed object. Freehand strokes and library definitions are unaffected.
    func deleteItem(_ id: UUID) {
        world.items.removeAll { $0.id == id }
    }

    /// Moves an object while reapplying the same rules used at initial placement.
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

    /// Moves an item to the end of the painter's-order array so it renders above its neighbors.
    func bringItemToFront(_ id: UUID) {
        guard let index = world.items.firstIndex(where: { $0.id == id }) else { return }
        var updatedWorld = world
        let item = updatedWorld.items.remove(at: index)
        updatedWorld.items.append(item)
        world = updatedWorld
    }

    /// Saves a completed freehand gesture. Single-point taps are discarded as accidental marks.
    func addStroke(_ stroke: DrawingStroke) {
        guard stroke.points.count > 1 else { return }
        world.strokes.append(stroke)
    }

    /// Atomically replaces the strokes used for recognition with a coherent catalog object.
    /// Placement is computed from the original drawing's bounds, preserving intent and scale.
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
    /// Converts one or more recent strokes into a reusable, named vector symbol.
    ///
    /// Points are translated into their combined bounding box and uniformly scaled into a unit
    /// square. Padding on the shorter axis preserves the drawing's aspect ratio rather than
    /// stretching it. This normalized representation can be rendered at any resolution by Metal.
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

    /// Deletes a custom definition and all instances that depend on it, avoiding orphaned items.
    func deleteCustomShape(_ id: String) {
        customShapes.removeAll { $0.id == id }
        world.items.removeAll { $0.shapeID == id }
        persistCustomShapes()
    }

    /// Removes only the most recently completed freehand stroke.
    func undoStroke() {
        guard !world.strokes.isEmpty else { return }
        world.strokes.removeLast()
    }

    /// Clears authored content but retains world-level choices such as terrain and scene width.
    /// The custom library is intentionally preserved because it belongs to the child, not a scene.
    func clear() {
        world = DrawtopiaWorld(
            name: world.name,
            terrain: world.terrain,
            weather: world.weather,
            sceneWidth: world.sceneWidth
        )
    }

    /// Encodes a compact JSON snapshot into app-local preferences.
    private func save() {
        guard let data = try? JSONEncoder().encode(world) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    /// Persists the reusable custom library independently of scene autosave.
    private func persistCustomShapes() {
        guard let data = try? JSONEncoder().encode(customShapes) else { return }
        UserDefaults.standard.set(data, forKey: customShapesKey)
    }
}
