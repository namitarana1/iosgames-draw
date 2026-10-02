import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: WorldStore
    @State private var tool: CreatorTool = .draw
    @State private var selectedColor = "#6C4CF1"
    @State private var isPlaying = false
    @State private var showTerrain = false
    @State private var showWeather = false
    @State private var showClearConfirmation = false
    @State private var showShapeLibrary = false

    private let palette = ["#6C4CF1", "#EF476F", "#FF9F1C", "#06D6A0", "#118AB2", "#2D3142", "#FFFFFF"]

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let compact = proxy.size.width < 700

                VStack(spacing: 0) {
                    WorldCanvasView(tool: $tool, colorHex: selectedColor, isPlaying: isPlaying)
                        .environmentObject(store)
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 28, style: .continuous))
                        .overlay(alignment: .topLeading) { modeBadge }
                        .overlay(alignment: .bottomTrailing) {
                            if isPlaying {
                                Text("Drag your explorer around!")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding()
                            }
                        }
                        .padding(compact ? 0 : 16)

                    if !isPlaying {
                        creatorControls(compact: compact)
                    }
                }
                .background(Color(red: 0.96, green: 0.95, blue: 1.0))
            }
            .navigationTitle(store.world.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog("Choose a landscape", isPresented: $showTerrain) {
                ForEach(Terrain.allCases) { terrain in
                    Button(terrain.title) { store.world.terrain = terrain }
                }
            }
            .confirmationDialog("Add a scene effect", isPresented: $showWeather) {
                ForEach(SceneWeather.allCases) { weather in
                    Button("\(store.world.weather == weather ? "✓ " : "")\(weather.title)") {
                        store.world.weather = weather
                    }
                }
            } message: {
                Text("The effect will animate when you press Play.")
            }
            .confirmationDialog("Start this world over?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Clear Everything", role: .destructive) { store.clear() }
            } message: {
                Text("Your drawings and buildings will be removed.")
            }
            .sheet(isPresented: $showShapeLibrary) {
                ShapeLibraryView()
                    .environmentObject(store)
            }
        }
        .tint(Color(hex: "#6C4CF1"))
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
    }

    private var modeBadge: some View {
        Label(isPlaying ? "Play Mode" : "Creator Mode", systemImage: isPlaying ? "gamecontroller.fill" : "sparkles")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()
    }

    @ViewBuilder
    private func creatorControls(compact: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(CreatorTool.allCases) { candidate in
                    Button {
                        tool = candidate
                    } label: {
                        Label(candidate.title, systemImage: candidate.symbol)
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(tool == candidate ? .white : .primary)
                            .background(tool == candidate ? Color(hex: "#6C4CF1") : Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if tool == .draw {
                        ForEach(palette, id: \.self) { hex in
                            Button { selectedColor = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(.white, lineWidth: selectedColor == hex ? 4 : 1))
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            }
                            .accessibilityLabel("Drawing color")
                        }

                        Divider().frame(height: 32)

                        Button { store.undoStroke() } label: {
                            Label("Undo line", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.world.strokes.isEmpty)
                    } else if tool == .build {
                        Label(
                            store.placementShapeID == nil ? "Drag objects • swipe empty space" : "Tap anywhere to place",
                            systemImage: store.placementShapeID == nil ? "hand.draw.fill" : "mappin.and.ellipse"
                        )
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)

                        Button { showShapeLibrary = true } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "square.grid.3x3.fill").font(.title2)
                                Text("All Shapes").font(.caption2.weight(.bold))
                            }
                            .frame(width: 72, height: 52)
                            .foregroundStyle(.white)
                            .background(Color(hex: "#6C4CF1"), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        ForEach(Array(ShapeCatalog.templates.prefix(10)), id: \.id) { shape in
                            Button { store.chooseForPlacement(shape.id) } label: {
                                VStack(spacing: 2) {
                                    ShapeArtworkView(shape: shape, dimension: 28)
                                    Text(shape.displayName).font(.caption2.weight(.semibold))
                                }
                                .frame(width: 62, height: 52)
                                .background(
                                    store.placementShapeID == shape.id ? Color(hex: "#DCD4FF") : .white.opacity(0.8),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Label("Tap a building to remove it", systemImage: "hand.tap.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, compact ? 12 : 24)
        .padding(.top, 10)
        .padding(.bottom, max(12, compact ? 8 : 16))
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { showTerrain = true } label: {
                Label("Landscape", systemImage: store.world.terrain.symbol)
            }
            Button { showWeather = true } label: {
                Label("Effects", systemImage: store.world.weather.symbol)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isPlaying {
                Button(role: .destructive) { showClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isPlaying.toggle()
                }
            } label: {
                Label(isPlaying ? "Create" : "Play", systemImage: isPlaying ? "paintbrush.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct ShapeLibraryView: View {
    @EnvironmentObject private var store: WorldStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory = "All"

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 12)]

    private var categories: [String] {
        ["All"] + (store.customShapes.isEmpty ? [] : ["My Shapes"])
            + Array(Set(ShapeCatalog.templates.map(\.category))).sorted()
    }

    private var filteredShapes: [ShapeTemplate] {
        ShapeCatalog.templates.filter { shape in
            let inCategory = selectedCategory == "All" || shape.category == selectedCategory
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchable = ([shape.displayName, shape.category] + shape.keywords).joined(separator: " ")
            return inCategory && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
    }

    private var filteredCustomShapes: [CustomShapeDefinition] {
        guard selectedCategory == "All" || selectedCategory == "My Shapes" else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.customShapes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { category in
                            Button(category) { selectedCategory = category }
                                .buttonStyle(.borderedProminent)
                                .tint(selectedCategory == category ? Color(hex: "#6C4CF1") : .gray.opacity(0.35))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredCustomShapes) { shape in
                            Button {
                                store.chooseForPlacement(shape.id)
                                dismiss()
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "scribble.variable")
                                        .font(.system(size: 34, weight: .medium))
                                        .foregroundStyle(Color(hex: shape.tintHex))
                                        .frame(height: 40)
                                    Text(shape.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 86)
                                .padding(8)
                                .background(Color(hex: shape.tintHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Shape", systemImage: "trash", role: .destructive) {
                                    store.deleteCustomShape(shape.id)
                                }
                            }
                            .accessibilityLabel("Add custom shape \(shape.name)")
                        }

                        ForEach(filteredShapes, id: \.id) { shape in
                            Button {
                                store.chooseForPlacement(shape.id)
                                dismiss()
                            } label: {
                                VStack(spacing: 8) {
                                    ShapeArtworkView(shape: shape, dimension: 40)
                                        .frame(height: 40)
                                    Text(shape.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 86)
                                .padding(8)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Shape Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: "Search \(ShapeCatalog.templates.count + store.customShapes.count) shapes"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ShapeArtworkView: View {
    let shape: ShapeTemplate
    let dimension: CGFloat

    @ViewBuilder
    var body: some View {
        if let paths = shape.vectorPaths {
            Canvas { context, canvasSize in
                for polygon in paths {
                    guard let first = polygon.first else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: first.x * canvasSize.width, y: first.y * canvasSize.height))
                    for point in polygon.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height))
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(hex: shape.tintHex)))
                }
            }
            .frame(width: dimension, height: dimension)
            .accessibilityHidden(true)
        } else {
            Image(uiImage: ShapeRasterizer.image(for: shape, size: max(dimension * 3, 96)))
                .resizable()
                .scaledToFit()
                .frame(width: dimension, height: dimension)
        }
    }
}
