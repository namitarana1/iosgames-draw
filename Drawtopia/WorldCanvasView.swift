import SwiftUI

/// Owns touch interaction and overlays while delegating all scene pixels to Metal.
///
/// Coordinates are normalized: one viewport is 1.0 units wide and the complete visible height is
/// 1.0. A wider world simply allows x to exceed 1.0; `cameraX` selects which one-unit slice is seen.
struct WorldCanvasView: View {
    @EnvironmentObject private var store: WorldStore
    @Binding var tool: CreatorTool
    let colorHex: String
    let isPlaying: Bool

    /// Points in the finger-down stroke that has not yet been committed to the world.
    @State private var activePoints: [NormalizedPoint] = []
    /// Play-mode avatar location is screen-relative because it represents the viewer, not scenery.
    @State private var explorer = CGPoint(x: 0.5, y: 0.72)

    // Gesture state distinguishes moving an object from panning empty world space. A single
    // DragGesture handles both so a zero-distance touch can also place, select, or erase an item.
    @State private var draggedItemID: UUID?
    @State private var selectedItemID: UUID?
    @State private var itemDragOffset = CGPoint.zero
    @State private var cameraX: Double = 0
    @State private var cameraAtDragStart: Double = 0
    @State private var isPanningScene = false
    /// Nearby strokes are batched as one recognition candidate until accepted or explicitly kept.
    @State private var candidateStrokes: [DrawingStroke] = []
    @State private var suggestions: [ShapeSuggestion] = []
    @State private var recognitionTask: Task<Void, Never>?
    @State private var showSaveShapePrompt = false
    @State private var customShapeName = ""

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                MetalWorldView(
                    world: store.world,
                    customShapes: store.customShapes,
                    selectedItemID: tool == .build && !isPlaying ? selectedItemID : nil,
                    activePoints: activePoints,
                    activeColorHex: colorHex,
                    explorer: explorer,
                    showExplorer: isPlaying,
                    cameraX: cameraX,
                    isPlaying: isPlaying
                )
                // The transparent representable must claim its whole rectangle for gestures.
                .contentShape(Rectangle())
                .gesture(worldGesture(in: geometry.size))

                sceneNavigator
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)

                if tool == .build, !isPlaying {
                    zoneGuide
                }

                if !suggestions.isEmpty, !isPlaying, tool == .draw {
                    suggestionBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minHeight: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Drawtopia world")
        .onChange(of: tool) { _, newTool in
            // A mode change means the child has chosen to keep any unresolved freehand drawing.
            keepOriginalDrawing()
            if newTool != .build { selectedItemID = nil }
        }
        .onChange(of: isPlaying) { _, _ in
            keepOriginalDrawing()
            selectedItemID = nil
        }
        .onDisappear { recognitionTask?.cancel() }
        .alert("Name Your Shape", isPresented: $showSaveShapePrompt) {
            TextField("Shape name", text: $customShapeName)
            Button("Cancel", role: .cancel) { customShapeName = "" }
            Button("Save") { saveCustomShape() }
                .disabled(customShapeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("It will appear in My Shapes and can be recognized in future drawings.")
        }
    }

    /// Page controls provide an accessible alternative to swiping and expose scene expansion.
    private var sceneNavigator: some View {
        HStack(spacing: 6) {
            Button { moveCamera(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(cameraX <= 0.001 || isPlaying)

            VStack(spacing: 1) {
                Text("Scene \(cameraPage) of \(Int(ceil(store.world.sceneWidth)))")
                    .font(.caption2.weight(.bold))
                Text(isPlaying ? "World is moving" : "Swipe empty space")
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(minWidth: 82)

            Button { moveCamera(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(cameraX >= maximumCameraX - 0.001 || isPlaying)

            if !isPlaying {
                Divider().frame(height: 22)
                Button { addHorizontalSpace() } label: {
                    Label("Space", systemImage: "plus")
                        .font(.caption2.weight(.bold))
                }
                .disabled(store.world.sceneWidth >= 20)
                .accessibilityLabel("Add horizontal scene space")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// A noninteractive teaching overlay that makes the semantic placement bands explicit.
    private var zoneGuide: some View {
        GeometryReader { proxy in
            zoneLabel("SKY", symbol: "bird.fill", color: .blue)
                .position(x: 48, y: proxy.size.height * 0.28)

            zoneLabel("MOUNTAINS • NO PLACEMENT", symbol: "mountain.2.fill", color: .gray)
                .position(x: 108, y: proxy.size.height * 0.55)

            zoneLabel("LAND", symbol: "leaf.fill", color: .green)
                .position(x: 52, y: proxy.size.height * 0.80)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func zoneLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var maximumCameraX: Double { max(store.world.sceneWidth - 1, 0) }

    /// Converts the continuous camera offset into a friendly one-based page number.
    private var cameraPage: Int {
        min(max(Int(cameraX.rounded()) + 1, 1), Int(ceil(store.world.sceneWidth)))
    }

    private func moveCamera(by distance: Double) {
        withAnimation(.easeInOut(duration: 0.28)) {
            cameraX = min(max(cameraX + distance, 0), maximumCameraX)
        }
        selectedItemID = nil
    }

    private func addHorizontalSpace() {
        let newWidth = store.addScenePage()
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraX = max(newWidth - 1, 0)
        }
        selectedItemID = nil
    }

    /// Presents the highest-scoring recognition results without replacing artwork automatically.
    /// The child always keeps final control: use a suggestion, keep the strokes, or name them.
    private var suggestionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Did you draw one of these?", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button("Keep mine") { keepOriginalDrawing() }
                    .font(.caption.weight(.semibold))
                Button("Save mine") {
                    customShapeName = ""
                    showSaveShapePrompt = true
                }
                .font(.caption.weight(.bold))
            }

            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        accept(suggestion)
                    } label: {
                        VStack(spacing: 2) {
                            if let template = ShapeCatalog.byID[suggestion.shapeID] {
                                ShapeArtworkView(shape: template, dimension: 28)
                            } else {
                                Image(systemName: "scribble.variable")
                                    .font(.system(size: 25, weight: .semibold))
                                    .foregroundStyle(Color(hex: suggestion.tintHex))
                            }
                            Text(suggestion.displayName)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(suggestion.displayName)")
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    /// Interprets a touch according to the current creator mode.
    ///
    /// - Draw records world-space points, so artwork remains attached to scenery while panning.
    /// - Build places a pending library object, drags a hit object, or pans from empty space.
    /// - Erase removes the visually topmost object under the finger.
    /// - Play moves the explorer in screen space while the world scrolls behind it.
    private func worldGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let screenLocation = normalized(value.location, in: size)
                let location = worldPoint(from: screenLocation)

                if isPlaying {
                    explorer = screenLocation
                    return
                }

                switch tool {
                case .draw:
                    // A new nearby stroke probably belongs to the same multi-stroke object. A far
                    // stroke starts a fresh recognition group and leaves the earlier art intact.
                    if activePoints.isEmpty, !candidateStrokes.isEmpty {
                        if belongsToCurrentCandidate(location) {
                            recognitionTask?.cancel()
                            suggestions.removeAll()
                        } else {
                            keepOriginalDrawing()
                        }
                    }
                    activePoints.append(NormalizedPoint(x: location.x, y: location.y))
                case .build:
                    if draggedItemID == nil, !isPanningScene {
                        let startScreen = normalized(value.startLocation, in: size)
                        let start = worldPoint(from: startScreen)

                        if let shapeID = store.placementShapeID {
                            // Placement becomes a drag immediately, allowing tap-and-position in
                            // one continuous gesture instead of requiring a second interaction.
                            let id = store.add(shapeID, at: start)
                            draggedItemID = id
                            selectedItemID = id
                            itemDragOffset = .zero
                        } else if let item = item(at: start, in: size) {
                            draggedItemID = item.id
                            selectedItemID = item.id
                            itemDragOffset = CGPoint(
                                x: item.x - start.x,
                                y: displayedY(for: item, in: size) - start.y
                            )
                            store.bringItemToFront(item.id)
                        } else {
                            // An empty-space drag navigates horizontally through the wider scene.
                            selectedItemID = nil
                            isPanningScene = true
                            cameraAtDragStart = cameraX
                        }
                    }

                    if isPanningScene {
                        // Dividing pixel travel by viewport width converts it to world pages.
                        let travel = Double(value.translation.width / max(size.width, 1))
                        cameraX = min(max(cameraAtDragStart - travel, 0), maximumCameraX)
                        return
                    }

                    guard let id = draggedItemID else { return }
                    store.moveItem(
                        id,
                        to: CGPoint(x: location.x + itemDragOffset.x, y: location.y + itemDragOffset.y)
                    )
                case .erase:
                    guard draggedItemID == nil,
                          let item = item(at: location, in: size, maximumDistance: 0.14) else { return }
                    draggedItemID = item.id
                    store.deleteItem(item.id)
                }
            }
            .onEnded { _ in
                if !isPlaying, tool == .draw {
                    // Width is stored with the stroke so saved art renders consistently later.
                    let stroke = DrawingStroke(points: activePoints, colorHex: colorHex, width: 7)
                    store.addStroke(stroke)
                    activePoints.removeAll(keepingCapacity: true)
                    if stroke.points.count > 1 {
                        candidateStrokes.append(stroke)
                        scheduleRecognition()
                    }
                }
                draggedItemID = nil
                isPanningScene = false
            }
    }

    /// Debounces recognition to let a child finish multi-stroke drawings such as a house or tree.
    /// Cancellation is expected whenever another related stroke begins before the delay expires.
    private func scheduleRecognition() {
        recognitionTask?.cancel()
        let batch = candidateStrokes
        recognitionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(2200))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let matches = ShapeMatcher.suggestions(for: batch, customShapes: store.customShapes)
            guard !matches.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                suggestions = matches
            }
        }
    }

    /// Replaces exactly the strokes in the current batch, leaving unrelated artwork untouched.
    private func accept(_ suggestion: ShapeSuggestion) {
        recognitionTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.replaceStrokes(candidateStrokes, with: suggestion.shapeID)
            candidateStrokes.removeAll()
            suggestions.removeAll()
        }
    }

    /// Stores a normalized copy in the personal library while keeping the original scene strokes.
    private func saveCustomShape() {
        recognitionTask?.cancel()
        guard store.saveCustomShape(name: customShapeName, from: candidateStrokes) != nil else { return }
        customShapeName = ""
        candidateStrokes.removeAll()
        suggestions.removeAll()
    }

    /// Ends recognition for the batch; committed strokes already remain in `world.strokes`.
    private func keepOriginalDrawing() {
        recognitionTask?.cancel()
        candidateStrokes.removeAll()
        suggestions.removeAll()
    }

    /// Uses an expanded bounding box to decide whether a new stroke belongs to the pending object.
    /// The adaptive margin accepts detached details (windows, leaves) without grouping distant art.
    private func belongsToCurrentCandidate(_ point: CGPoint) -> Bool {
        let points = candidateStrokes.flatMap { $0.points.map(\.cgPoint) }
        guard let first = points.first else { return false }
        let bounds = points.dropFirst().reduce(
            (minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        ) { bounds, candidate in
            (
                min(bounds.minX, candidate.x),
                max(bounds.maxX, candidate.x),
                min(bounds.minY, candidate.y),
                max(bounds.maxY, candidate.y)
            )
        }
        let span = max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
        let margin = min(max(span * 0.75, 0.12), 0.22)
        return point.x >= bounds.minX - margin && point.x <= bounds.maxX + margin
            && point.y >= bounds.minY - margin && point.y <= bounds.maxY + margin
    }

    /// Converts UIKit points into a safely inset 0...1 viewport coordinate.
    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0.02), 0.98),
            y: min(max(point.y / max(size.height, 1), 0.02), 0.98)
        )
    }

    /// Adds the horizontal camera origin; vertical coordinates do not scroll.
    private func worldPoint(from screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x + cameraX, y: screenPoint.y)
    }

    /// Hit-tests in reverse painter's order so the visible top object wins when shapes overlap.
    private func item(at point: CGPoint, in size: CGSize, maximumDistance: CGFloat? = nil) -> WorldItem? {
        store.world.items.reversed().first { item in
            let hitRadius = maximumDistance ?? max(0.10, 0.09 * item.scale)
            return hypot(item.x - point.x, displayedY(for: item, in: size) - point.y) <= hitRadius
        }
    }

    /// Mirrors the render-time placement constraint so hit testing matches the visible object.
    private func displayedY(for item: WorldItem, in _: CGSize) -> Double {
        SceneLayout.constrainedY(for: item.shapeID, proposedY: item.y)
    }
}
