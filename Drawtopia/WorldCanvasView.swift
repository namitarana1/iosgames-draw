import SwiftUI

struct WorldCanvasView: View {
    @EnvironmentObject private var store: WorldStore
    @Binding var tool: CreatorTool
    let colorHex: String
    let isPlaying: Bool

    @State private var activePoints: [NormalizedPoint] = []
    @State private var explorer = CGPoint(x: 0.5, y: 0.72)
    @State private var draggedItemID: UUID?
    @State private var selectedItemID: UUID?
    @State private var itemDragOffset = CGPoint.zero
    @State private var cameraX: Double = 0
    @State private var cameraAtDragStart: Double = 0
    @State private var isPanningScene = false
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
                            selectedItemID = nil
                            isPanningScene = true
                            cameraAtDragStart = cameraX
                        }
                    }

                    if isPanningScene {
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

    private func accept(_ suggestion: ShapeSuggestion) {
        recognitionTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.replaceStrokes(candidateStrokes, with: suggestion.shapeID)
            candidateStrokes.removeAll()
            suggestions.removeAll()
        }
    }

    private func saveCustomShape() {
        recognitionTask?.cancel()
        guard store.saveCustomShape(name: customShapeName, from: candidateStrokes) != nil else { return }
        customShapeName = ""
        candidateStrokes.removeAll()
        suggestions.removeAll()
    }

    private func keepOriginalDrawing() {
        recognitionTask?.cancel()
        candidateStrokes.removeAll()
        suggestions.removeAll()
    }

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

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0.02), 0.98),
            y: min(max(point.y / max(size.height, 1), 0.02), 0.98)
        )
    }

    private func worldPoint(from screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x + cameraX, y: screenPoint.y)
    }

    private func item(at point: CGPoint, in size: CGSize, maximumDistance: CGFloat? = nil) -> WorldItem? {
        store.world.items.reversed().first { item in
            let hitRadius = maximumDistance ?? max(0.10, 0.09 * item.scale)
            return hypot(item.x - point.x, displayedY(for: item, in: size) - point.y) <= hitRadius
        }
    }

    private func displayedY(for item: WorldItem, in _: CGSize) -> Double {
        SceneLayout.constrainedY(for: item.shapeID, proposedY: item.y)
    }
}
