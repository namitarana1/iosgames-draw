import SwiftUI
import MetalKit

/// SwiftUI bridge for the app's Metal renderer.
///
/// SwiftUI owns state and layout, while `MTKView` owns the actual scene surface. This separation
/// keeps gestures and controls idiomatic without falling back to a 2D Canvas for world rendering.
struct MetalWorldView: UIViewRepresentable {
    let world: DrawtopiaWorld
    let customShapes: [CustomShapeDefinition]
    let selectedItemID: UUID?
    let activePoints: [NormalizedPoint]
    let activeColorHex: String
    let explorer: CGPoint
    let showExplorer: Bool
    let cameraX: Double
    let isPlaying: Bool

    func makeCoordinator() -> MetalWorldRenderer { MetalWorldRenderer() }

    /// Creates the Metal surface once and compiles both solid-color and textured pipelines.
    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Drawtopia requires a Metal-capable device")
        }
        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        // Creator mode renders only when state changes; Play mode switches to a continuous 60 fps
        // loop in `updateUIView`. Avoiding idle frames reduces heat and battery use while drawing.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        context.coordinator.prepare(device: device, pixelFormat: view.colorPixelFormat)
        return view
    }

    /// Copies the latest value-type model into the long-lived renderer coordinator.
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.world = world
        context.coordinator.customShapes = customShapes
        context.coordinator.selectedItemID = selectedItemID
        context.coordinator.activePoints = activePoints
        context.coordinator.activeColor = GPUColor(hex: activeColorHex)
        context.coordinator.explorer = explorer
        context.coordinator.showExplorer = showExplorer
        context.coordinator.cameraX = cameraX
        context.coordinator.setPlaying(isPlaying)
        view.isPaused = !isPlaying
        view.enableSetNeedsDisplay = !isPlaying
        view.setNeedsDisplay()
    }
}

/// Immediate-mode Metal renderer for terrain, strokes, objects, animation, and effects.
/// All CPU-side positions use normalized top-left coordinates; the vertex shader converts them to
/// Metal's clip space. This makes the same scene data resolution-independent on iPhone and iPad.
final class MetalWorldRenderer: NSObject, MTKViewDelegate {
    // These values are supplied by SwiftUI before each requested frame.
    var world = DrawtopiaWorld()
    var customShapes: [CustomShapeDefinition] = []
    var selectedItemID: UUID?
    var activePoints: [NormalizedPoint] = []
    var activeColor = GPUColor(hex: "#6C4CF1")
    var explorer = CGPoint(x: 0.5, y: 0.72)
    var showExplorer = false
    var cameraX: Double = 0
    var isPlaying = false

    // Metal resources live for the coordinator's lifetime. Textures are cached by catalog id so an
    // SF Symbol is rasterized and uploaded only once, even when many copies appear in the world.
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texturePipeline: MTLRenderPipelineState?
    private var textureCache: [String: MTLTexture] = [:]
    private var pixelAspect: Double = 1
    private var animationStart = CACurrentMediaTime()
    private var animationTime: Double = 0
    private var renderCameraX: Double = 0

    /// Resets animation phase only on the transition into Play, not on routine SwiftUI updates.
    func setPlaying(_ playing: Bool) {
        if playing, !isPlaying {
            animationStart = CACurrentMediaTime()
        }
        isPlaying = playing
    }

    /// Compiles two tiny shader pipelines: vertex-colored geometry and alpha-blended artwork.
    func prepare(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        commandQueue = device.makeCommandQueue()

        // The solid vertex shader maps 0...1 top-left UI coordinates to -1...1 bottom-left clip
        // coordinates. The texture shader performs the same transform while passing UV values.
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float2 position; float4 color; };
        struct RasterData { float4 position [[position]]; float4 color; };
        vertex RasterData vertex_main(const device Vertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
            RasterData out;
            float2 p = vertices[id].position;
            out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
            out.color = vertices[id].color;
            return out;
        }
        fragment float4 fragment_main(RasterData in [[stage_in]]) { return in.color; }

        struct TextureVertex { float2 position; float2 uv; };
        struct TextureRasterData { float4 position [[position]]; float2 uv; };
        vertex TextureRasterData texture_vertex(const device TextureVertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
            TextureRasterData out;
            float2 p = vertices[id].position;
            out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
            out.uv = vertices[id].uv;
            return out;
        }
        fragment float4 texture_fragment(TextureRasterData in [[stage_in]], texture2d<float> artwork [[texture(0)]]) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            return artwork.sample(textureSampler, in.uv);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            // Conventional source-alpha blending is required for translucent weather and edges.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let textureDescriptor = MTLRenderPipelineDescriptor()
            textureDescriptor.vertexFunction = library.makeFunction(name: "texture_vertex")
            textureDescriptor.fragmentFunction = library.makeFunction(name: "texture_fragment")
            textureDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            textureDescriptor.colorAttachments[0].isBlendingEnabled = true
            textureDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            textureDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            texturePipeline = try device.makeRenderPipelineState(descriptor: textureDescriptor)
        } catch {
            assertionFailure("Unable to create Metal renderer: \(error)")
        }
    }

    /// Captures drawable aspect ratio so authored circles and objects stay visually proportional.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        pixelAspect = size.height > 0 ? size.width / size.height : 1
    }

    /// Encodes one frame in painter's order: terrain, drawings, objects, avatar, then weather.
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let queue = commandQueue,
              let pipeline,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        animationTime = CACurrentMediaTime() - animationStart
        // Play mode advances the camera automatically and wraps through the full scene. Creator
        // mode uses the exact manually selected page so placed objects never drift under a finger.
        renderCameraX = isPlaying
            ? positiveRemainder(cameraX + animationTime * 0.075, modulus: world.sceneWidth)
            : cameraX

        let background = terrainBackground(world.terrain)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(background.r), green: Double(background.g), blue: Double(background.b), alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)

        drawTerrain(world.terrain, encoder: encoder)
        for stroke in world.strokes {
            polyline(stroke.points, color: GPUColor(hex: stroke.colorHex), encoder: encoder)
        }
        polyline(activePoints, color: activeColor, encoder: encoder)
        for item in world.items {
            let renderedItem = renderItem(item)
            // Cull with a small margin so large objects enter smoothly at screen edges.
            guard renderedItem.x > -0.2, renderedItem.x < 1.2 else { continue }
            draw(renderedItem, encoder: encoder)
            if item.id == selectedItemID { drawSelection(around: renderedItem, encoder: encoder) }
        }
        if showExplorer { drawExplorer(at: explorer, encoder: encoder) }
        drawWeather(world.weather, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Draws terrain as multiple parallax layers. Near details track the camera fully, mountains
    /// move more slowly, and sky objects move least, creating depth while the background travels.
    private func drawTerrain(_ terrain: Terrain, encoder: MTLRenderCommandEncoder) {
        let distantShift = positiveRemainder(renderCameraX * 0.48, modulus: 1.44)
        let skyShift = positiveRemainder(renderCameraX * 0.12, modulus: 1.2)
        switch terrain {
        case .meadow:
            rectangle(center: CGPoint(x: 0.5, y: 0.84), size: CGSize(width: 1.2, height: 0.40), color: GPUColor(0.30, 0.68, 0.25), encoder: encoder)
            circle(center: CGPoint(x: 0.92 - skyShift, y: 0.15), radius: 0.065, color: GPUColor(1, 0.82, 0.18), encoder: encoder)
            drawRockyMountains(offset: distantShift, encoder: encoder)
            drawMovingGroundDetails(for: terrain, encoder: encoder)
        case .desert:
            rectangle(center: CGPoint(x: 0.5, y: 0.82), size: CGSize(width: 1.2, height: 0.42), color: GPUColor(0.92, 0.55, 0.22), encoder: encoder)
            circle(center: CGPoint(x: 0.90 - skyShift, y: 0.16), radius: 0.075, color: GPUColor(1, 0.86, 0.18), encoder: encoder)
            drawRollingHills(offset: distantShift, color: GPUColor(0.82, 0.42, 0.17), encoder: encoder)
            drawMovingGroundDetails(for: terrain, encoder: encoder)
        case .ocean:
            // Alternating directions and per-row rates prevent the water from reading as one slab.
            for row in 0..<6 {
                let direction = row.isMultiple(of: 2) ? 1.0 : -1.0
                let layerShift = renderCameraX * (0.42 + Double(row) * 0.08)
                let center = positiveRemainder(0.22 + Double(row) * 0.19 - direction * layerShift, modulus: 1.35) - 0.15
                rectangle(center: CGPoint(x: center, y: 0.22 + Double(row) * 0.13), size: CGSize(width: 0.55, height: 0.014), color: GPUColor(1, 1, 1, 0.18), encoder: encoder)
            }
            drawMovingGroundDetails(for: terrain, encoder: encoder)
        case .moon:
            rectangle(center: CGPoint(x: 0.5, y: 0.88), size: CGSize(width: 1.2, height: 0.28), color: GPUColor(0.46, 0.46, 0.58), encoder: encoder)
            // Integer arithmetic provides deterministic star positions without storing particles.
            for seed in 0..<18 {
                let starX = positiveRemainder(Double((seed * 47 + 31) % 101) / 100 - skyShift * 0.22, modulus: 1)
                let p = CGPoint(x: starX, y: Double((seed * 71 + 13) % 67) / 100)
                circle(center: p, radius: seed.isMultiple(of: 4) ? 0.006 : 0.003, color: GPUColor(1, 1, 1, 0.8), segments: 8, encoder: encoder)
            }
            drawMovingGroundDetails(for: terrain, encoder: encoder)
        }
    }

    /// Selects the correct representation for a placed item: articulated animal, custom vector,
    /// catalog polygon, or textured SF Symbol fallback.
    private func draw(_ item: WorldItem, encoder: MTLRenderCommandEncoder) {
        if isPlaying, let style = animalMotionStyle(for: item.shapeID), style != .still {
            drawAnimatedAnimal(item, style: style, encoder: encoder)
            return
        }

        if let custom = customShapes.first(where: { $0.id == item.shapeID }) {
            draw(custom, as: item, encoder: encoder)
            return
        }

        if let definition = ShapeCatalog.byID[item.shapeID], definition.vectorPaths != nil {
            draw(definition, as: item, encoder: encoder)
            return
        }

        guard let definition = ShapeCatalog.byID[item.shapeID],
              let texture = texture(for: definition),
              let texturePipeline,
              let pipeline else { return }

        // A textured item is two triangles. `pixelAspect` compensates normalized y coordinates for
        // the view's physical aspect ratio, preventing square artwork from appearing stretched.
        let halfWidth = 0.075 * item.scale
        let halfHeight = halfWidth * pixelAspect
        let x = item.x, y = item.y
        let vertices = [
            TextureVertex(CGPoint(x: x-halfWidth, y: y-halfHeight), SIMD2(0, 0)),
            TextureVertex(CGPoint(x: x+halfWidth, y: y-halfHeight), SIMD2(1, 0)),
            TextureVertex(CGPoint(x: x-halfWidth, y: y+halfHeight), SIMD2(0, 1)),
            TextureVertex(CGPoint(x: x+halfWidth, y: y-halfHeight), SIMD2(1, 0)),
            TextureVertex(CGPoint(x: x+halfWidth, y: y+halfHeight), SIMD2(1, 1)),
            TextureVertex(CGPoint(x: x-halfWidth, y: y+halfHeight), SIMD2(0, 1))
        ]
        guard let device,
              let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<TextureVertex>.stride * vertices.count) else { return }
        encoder.setRenderPipelineState(texturePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.setRenderPipelineState(pipeline)
    }

    /// Expands normalized catalog polygons around the item's center and triangulates each as a fan.
    /// Catalog paths are authored as simple convex silhouettes; concave assets should be split into
    /// multiple paths in JSON so every fan remains valid.
    private func draw(_ definition: ShapeTemplate, as item: WorldItem, encoder: MTLRenderCommandEncoder) {
        guard let paths = definition.vectorPaths else { return }
        let halfWidth = 0.075 * item.scale
        let halfHeight = halfWidth * pixelAspect
        let color = GPUColor(hex: definition.tintHex)

        for path in paths where path.count >= 3 {
            let mapped = path.map { point in
                CGPoint(
                    x: item.x + (point.x - 0.5) * halfWidth * 2,
                    y: item.y + (point.y - 0.5) * halfHeight * 2
                )
            }
            var vertices: [GPUVertex] = []
            for index in 1..<(mapped.count - 1) {
                vertices.append(GPUVertex(mapped[0], color))
                vertices.append(GPUVertex(mapped[index], color))
                vertices.append(GPUVertex(mapped[index + 1], color))
            }
            submit(vertices, primitive: .triangle, encoder: encoder)
        }
    }

    /// Renders child-authored custom shapes as line strips, preserving their original stroke style.
    private func draw(_ custom: CustomShapeDefinition, as item: WorldItem, encoder: MTLRenderCommandEncoder) {
        let halfWidth = 0.075 * item.scale
        let halfHeight = halfWidth * pixelAspect
        let color = GPUColor(hex: custom.tintHex)
        for path in custom.paths where path.count > 1 {
            let vertices = path.map { point in
                GPUVertex(
                    CGPoint(
                        x: item.x + (point.x - 0.5) * halfWidth * 2,
                        y: item.y + (point.y - 0.5) * halfHeight * 2
                    ),
                    color
                )
            }
            submit(vertices, primitive: .lineStrip, encoder: encoder)
        }
    }

    /// Rasterizes an SF Symbol to a GPU texture on first use, then reuses the uploaded texture.
    private func texture(for definition: ShapeTemplate) -> MTLTexture? {
        if let cached = textureCache[definition.id] { return cached }
        guard let device else { return nil }
        let image = ShapeRasterizer.image(for: definition, size: 128)
        guard let cgImage = image.cgImage,
              let texture = try? MTKTextureLoader(device: device).newTexture(
                cgImage: cgImage,
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
              ) else { return nil }
        textureCache[definition.id] = texture
        return texture
    }

    /// Draws a simple screen-space explorer avatar above the scrolling world in Play mode.
    private func drawExplorer(at p: CGPoint, encoder: MTLRenderCommandEncoder) {
        circle(center: CGPoint(x: p.x, y: p.y - 0.035), radius: 0.048, color: GPUColor(0.94, 0.96, 1, 0.8), encoder: encoder)
        circle(center: CGPoint(x: p.x, y: p.y - 0.035), radius: 0.034, color: GPUColor(1, 0.82, 0.58), encoder: encoder)
        rectangle(center: CGPoint(x: p.x, y: p.y + 0.035), size: CGSize(width: 0.065, height: 0.09), color: GPUColor(0.45, 0.30, 0.86), encoder: encoder)
    }

    /// Produces a temporary screen-space item without mutating the saved model.
    ///
    /// Animals travel independently through world space; their UUID seeds subtle speed and phase
    /// variation so a group does not march in lockstep. Vertical motion depends on locomotion type,
    /// and the placement constraint is reapplied afterward so land creatures never float.
    private func renderItem(_ item: WorldItem) -> WorldItem {
        var rendered = item
        var worldX = item.x
        rendered.y = SceneLayout.constrainedY(for: item.shapeID, proposedY: item.y)
        if isPlaying, isAnimal(item.shapeID) {
            let speedSeed = item.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            let speed = 0.14 + Double(speedSeed % 5) * 0.018
            worldX = positiveRemainder(item.x + animationTime * speed, modulus: world.sceneWidth)
            switch animalMotionStyle(for: item.shapeID) {
            case .flyer:
                rendered.y += sin(animationTime * 3.2 + Double(speedSeed)) * 0.055
            case .swimmer:
                rendered.y += sin(animationTime * 2.8 + Double(speedSeed)) * 0.018
            case .hopper:
                rendered.y -= abs(sin(animationTime * 4.5 + Double(speedSeed))) * 0.055
            case .quadruped, .walker, .crawler:
                rendered.y += abs(sin(animationTime * 7.5 + Double(speedSeed))) * 0.004
            case .still, .none:
                break
            }
            rendered.y = SceneLayout.constrainedY(for: item.shapeID, proposedY: rendered.y)
        }
        rendered.x = screenX(worldX)
        return rendered
    }

    /// Uses catalog semantics, rather than id spelling, to determine whether an item may locomote.
    private func isAnimal(_ shapeID: String) -> Bool {
        guard let category = ShapeCatalog.byID[shapeID]?.category else { return false }
        return category == "Animals" || category == "Wildlife"
    }

    /// Maps animals to locomotion rigs. Unknown animal entries get the general quadruped gait.
    private func animalMotionStyle(for shapeID: String) -> AnimalMotionStyle? {
        guard isAnimal(shapeID) else { return nil }
        switch shapeID {
        case "bird", "owl", "eagle", "butterfly", "bee", "ladybug": return .flyer
        case "fish": return .swimmer
        case "rabbit", "frog": return .hopper
        case "chicken", "duck": return .walker
        case "turtle", "ant", "lizard", "snake": return .crawler
        case "paw": return .still
        default: return .quadruped
        }
    }

    /// Dispatches an animal to its procedural rig with a stable per-instance phase offset.
    private func drawAnimatedAnimal(_ item: WorldItem, style: AnimalMotionStyle, encoder: MTLRenderCommandEncoder) {
        let color = GPUColor(hex: ShapeCatalog.byID[item.shapeID]?.tintHex ?? "#9C6644")
        let seed = item.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let phase = animationTime * 8 + Double(seed % 17) * 0.2
        switch style {
        case .quadruped:
            drawQuadruped(item, color: color, phase: phase, encoder: encoder)
        case .walker:
            drawWalkingBird(item, color: color, phase: phase, encoder: encoder)
        case .flyer:
            drawFlyingAnimal(item, color: color, phase: phase, encoder: encoder)
        case .swimmer:
            drawSwimmingAnimal(item, color: color, phase: phase, encoder: encoder)
        case .hopper:
            drawHoppingAnimal(item, color: color, phase: phase, encoder: encoder)
        case .crawler:
            drawCrawlingAnimal(item, color: color, phase: phase, encoder: encoder)
        case .still:
            break
        }
    }

    /// Four-beat quadruped gait with diagonal limb pairs out of phase.
    /// Each leg has hip, knee, and foot points so it bends rather than rotating as a rigid stick;
    /// the body stays grounded while the tail uses a slower independent wag.
    private func drawQuadruped(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        let dark = GPUColor(color.r * 0.72, color.g * 0.72, color.b * 0.72, color.a)
        let groundY = item.y + h
        let hipY = item.y + h * 0.05

        for (hip, offset, shade) in [
            (-0.38, .pi, dark), (0.32, 0.0, dark),
            (-0.27, 0.0, color), (0.43, .pi, color)
        ] {
            let swing = sin(phase + offset)
            let hipPoint = CGPoint(x: item.x + hip * w, y: hipY)
            let knee = CGPoint(x: hipPoint.x + swing * w * 0.28, y: item.y + h * 0.45)
            let foot = CGPoint(x: hipPoint.x - swing * w * 0.34, y: groundY)
            thickSegment(from: hipPoint, to: knee, width: w * 0.12, color: shade, encoder: encoder)
            thickSegment(from: knee, to: foot, width: w * 0.10, color: shade, encoder: encoder)
        }

        rectangle(center: CGPoint(x: item.x - w * 0.08, y: item.y - h * 0.18), size: CGSize(width: w * 1.25, height: h * 0.62), color: color, encoder: encoder)
        circle(center: CGPoint(x: item.x + w * 0.60, y: item.y - h * 0.38), radius: w * 0.30, color: color, segments: 20, encoder: encoder)
        rectangle(center: CGPoint(x: item.x + w * 0.82, y: item.y - h * 0.28), size: CGSize(width: w * 0.35, height: h * 0.20), color: color, encoder: encoder)
        triangle(
            CGPoint(x: item.x + w * 0.40, y: item.y - h * 0.58),
            CGPoint(x: item.x + w * 0.62, y: item.y - h * 0.76),
            CGPoint(x: item.x + w * 0.68, y: item.y - h * 0.48),
            dark,
            encoder
        )
        let tailTip = CGPoint(
            x: item.x - w * 0.96,
            y: item.y - h * (0.30 + sin(phase * 0.55) * 0.22)
        )
        thickSegment(from: CGPoint(x: item.x - w * 0.67, y: item.y - h * 0.28), to: tailTip, width: w * 0.10, color: color, encoder: encoder)
        circle(center: CGPoint(x: item.x + w * 0.67, y: item.y - h * 0.43), radius: w * 0.035, color: GPUColor(0.08, 0.08, 0.08), segments: 10, encoder: encoder)
    }

    /// Two-beat bird walk with alternating feet and a body/head/beak silhouette.
    private func drawWalkingBird(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        let groundY = item.y + h
        for (offset, hipX) in [(0.0, -0.15), (Double.pi, 0.16)] {
            let swing = sin(phase + offset)
            let hip = CGPoint(x: item.x + hipX * w, y: item.y + h * 0.18)
            let foot = CGPoint(x: hip.x + swing * w * 0.38, y: groundY)
            thickSegment(from: hip, to: foot, width: w * 0.075, color: GPUColor(0.82, 0.50, 0.14), encoder: encoder)
            thickSegment(from: foot, to: CGPoint(x: foot.x + w * 0.18, y: groundY), width: w * 0.055, color: GPUColor(0.82, 0.50, 0.14), encoder: encoder)
        }
        circle(center: CGPoint(x: item.x - w * 0.10, y: item.y - h * 0.20), radius: w * 0.52, color: color, segments: 22, encoder: encoder)
        circle(center: CGPoint(x: item.x + w * 0.45, y: item.y - h * 0.50), radius: w * 0.27, color: color, segments: 18, encoder: encoder)
        triangle(CGPoint(x: item.x + w * 0.68, y: item.y - h * 0.52), CGPoint(x: item.x + w, y: item.y - h * 0.40), CGPoint(x: item.x + w * 0.68, y: item.y - h * 0.31), GPUColor(0.95, 0.62, 0.12), encoder)
    }

    /// Symmetric wing flap for birds and insects; vertical travel is applied by `renderItem`.
    private func drawFlyingAnimal(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        let flap = sin(phase * 1.25)
        circle(center: CGPoint(x: item.x, y: item.y), radius: w * 0.34, color: color, segments: 20, encoder: encoder)
        triangle(CGPoint(x: item.x - w * 0.12, y: item.y), CGPoint(x: item.x - w * 0.92, y: item.y - h * flap * 0.75), CGPoint(x: item.x - w * 0.48, y: item.y + h * 0.18), color, encoder)
        triangle(CGPoint(x: item.x + w * 0.12, y: item.y), CGPoint(x: item.x + w * 0.82, y: item.y - h * flap * 0.75), CGPoint(x: item.x + w * 0.43, y: item.y + h * 0.18), color, encoder)
        triangle(CGPoint(x: item.x + w * 0.28, y: item.y - h * 0.10), CGPoint(x: item.x + w * 0.72, y: item.y), CGPoint(x: item.x + w * 0.28, y: item.y + h * 0.10), GPUColor(0.95, 0.67, 0.16), encoder)
    }

    /// Fish rig with a sinusoidal tail and a darker pectoral fin to communicate propulsion.
    private func drawSwimmingAnimal(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        circle(center: CGPoint(x: item.x + w * 0.10, y: item.y), radius: w * 0.48, color: color, segments: 22, encoder: encoder)
        let tailWave = sin(phase) * h * 0.42
        triangle(CGPoint(x: item.x - w * 0.30, y: item.y), CGPoint(x: item.x - w, y: item.y - h * 0.58 + tailWave), CGPoint(x: item.x - w * 0.90, y: item.y + h * 0.58 + tailWave), color, encoder)
        triangle(CGPoint(x: item.x + w * 0.02, y: item.y), CGPoint(x: item.x - w * 0.24, y: item.y + h * 0.55), CGPoint(x: item.x + w * 0.38, y: item.y + h * 0.20), GPUColor(color.r * 0.78, color.g * 0.78, color.b * 0.78), encoder)
        circle(center: CGPoint(x: item.x + w * 0.34, y: item.y - h * 0.12), radius: w * 0.035, color: GPUColor(0.05, 0.05, 0.08), segments: 9, encoder: encoder)
    }

    /// Compresses and extends rear legs in phase with the whole-body hop from `renderItem`.
    private func drawHoppingAnimal(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        let extensionAmount = abs(sin(phase * 0.56))
        circle(center: CGPoint(x: item.x - w * 0.15, y: item.y - h * 0.10), radius: w * 0.46, color: color, segments: 20, encoder: encoder)
        circle(center: CGPoint(x: item.x + w * 0.40, y: item.y - h * 0.42), radius: w * 0.27, color: color, segments: 18, encoder: encoder)
        thickSegment(from: CGPoint(x: item.x - w * 0.28, y: item.y + h * 0.12), to: CGPoint(x: item.x - w * (0.70 + extensionAmount * 0.22), y: item.y + h * 0.78), width: w * 0.15, color: color, encoder: encoder)
        thickSegment(from: CGPoint(x: item.x + w * 0.05, y: item.y + h * 0.12), to: CGPoint(x: item.x + w * (0.50 + extensionAmount * 0.28), y: item.y + h * 0.82), width: w * 0.13, color: color, encoder: encoder)
        thickSegment(from: CGPoint(x: item.x + w * 0.30, y: item.y - h * 0.62), to: CGPoint(x: item.x + w * 0.18, y: item.y - h), width: w * 0.11, color: color, encoder: encoder)
        thickSegment(from: CGPoint(x: item.x + w * 0.48, y: item.y - h * 0.62), to: CGPoint(x: item.x + w * 0.55, y: item.y - h), width: w * 0.11, color: color, encoder: encoder)
    }

    /// Uses a traveling sine wave for snakes and alternating small legs for other crawlers.
    private func drawCrawlingAnimal(_ item: WorldItem, color: GPUColor, phase: Double, encoder: MTLRenderCommandEncoder) {
        let w = 0.075 * item.scale
        let h = w * pixelAspect
        if item.shapeID == "snake" {
            let points = (0...12).map { index in
                let progress = Double(index) / 12
                return CGPoint(
                    x: item.x - w + progress * w * 2,
                    y: item.y + sin(progress * .pi * 4 + phase) * h * 0.25
                )
            }
            for pair in zip(points, points.dropFirst()) {
                thickSegment(from: pair.0, to: pair.1, width: w * 0.16, color: color, encoder: encoder)
            }
            return
        }
        rectangle(center: CGPoint(x: item.x, y: item.y - h * 0.10), size: CGSize(width: w * 1.30, height: h * 0.48), color: color, encoder: encoder)
        circle(center: CGPoint(x: item.x + w * 0.72, y: item.y - h * 0.12), radius: w * 0.22, color: color, segments: 16, encoder: encoder)
        for index in 0..<3 {
            let x = item.x - w * 0.42 + Double(index) * w * 0.40
            let swing = sin(phase + Double(index) * .pi) * w * 0.22
            thickSegment(from: CGPoint(x: x, y: item.y), to: CGPoint(x: x + swing, y: item.y + h * 0.58), width: w * 0.07, color: color, encoder: encoder)
            thickSegment(from: CGPoint(x: x, y: item.y), to: CGPoint(x: x - swing, y: item.y - h * 0.52), width: w * 0.07, color: color, encoder: encoder)
        }
    }

    /// Converts a mathematical line segment to a six-vertex rectangle with predictable thickness.
    private func thickSegment(from start: CGPoint, to end: CGPoint, width: Double, color: GPUColor, encoder: MTLRenderCommandEncoder) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        let px = -dy / length * width * 0.5
        let py = dx / length * width * 0.5
        submit([
            GPUVertex(CGPoint(x: start.x + px, y: start.y + py), color),
            GPUVertex(CGPoint(x: start.x - px, y: start.y - py), color),
            GPUVertex(CGPoint(x: end.x + px, y: end.y + py), color),
            GPUVertex(CGPoint(x: start.x - px, y: start.y - py), color),
            GPUVertex(CGPoint(x: end.x - px, y: end.y - py), color),
            GPUVertex(CGPoint(x: end.x + px, y: end.y + py), color)
        ], primitive: .triangle, encoder: encoder)
    }

    /// Converts world x to viewport x. Play-mode wrapping lets objects re-enter from the left after
    /// passing the far edge of a multi-page scene; creator mode never wraps while editing.
    private func screenX(_ worldX: Double) -> Double {
        var result = worldX - renderCameraX
        if isPlaying {
            let width = max(world.sceneWidth, 1)
            while result < -0.2 { result += width }
            while result >= width - 0.2 { result -= width }
        }
        return result
    }

    /// Repeating desert silhouettes form the middle-distance parallax layer.
    private func drawRollingHills(offset: Double, color: GPUColor, encoder: MTLRenderCommandEncoder) {
        for index in -2...5 {
            let x = Double(index) * 0.48 - offset
            triangle(
                CGPoint(x: x - 0.34, y: SceneLayout.groundLine(for: .desert)),
                CGPoint(x: x, y: 0.47 + Double((index + 4) % 2) * 0.04),
                CGPoint(x: x + 0.34, y: SceneLayout.groundLine(for: .desert)),
                color,
                encoder
            )
        }
    }

    /// Neutral rock and snow colors keep mountains distinct from plantable green land.
    private func drawRockyMountains(offset: Double, encoder: MTLRenderCommandEncoder) {
        for index in -2...5 {
            let x = Double(index) * 0.48 - offset
            let peakY = 0.43 + Double((index + 6) % 2) * 0.045
            let baseY = SceneLayout.groundLine(for: .meadow)
            let rock = (index + 6).isMultiple(of: 2)
                ? GPUColor(0.31, 0.43, 0.50)
                : GPUColor(0.39, 0.50, 0.56)
            triangle(
                CGPoint(x: x - 0.34, y: baseY),
                CGPoint(x: x, y: peakY),
                CGPoint(x: x + 0.34, y: baseY),
                rock,
                encoder
            )
            triangle(
                CGPoint(x: x - 0.075, y: peakY + 0.055),
                CGPoint(x: x, y: peakY),
                CGPoint(x: x + 0.075, y: peakY + 0.055),
                GPUColor(0.92, 0.96, 0.98, 0.92),
                encoder
            )
        }
    }

    /// Repeats terrain-specific near-field details at camera speed to anchor background movement.
    private func drawMovingGroundDetails(for terrain: Terrain, encoder: MTLRenderCommandEncoder) {
        let spacing = 0.24
        let shift = positiveRemainder(renderCameraX, modulus: spacing)
        for index in -1...6 {
            let x = Double(index) * spacing - shift
            let variant = Double((index + 8) % 4)
            switch terrain {
            case .meadow:
                let color = GPUColor(0.14, 0.47, 0.19, 0.72)
                let y = 0.76 + variant * 0.055
                submit([
                    GPUVertex(CGPoint(x: x - 0.014, y: y + 0.025), color),
                    GPUVertex(CGPoint(x: x, y: y), color),
                    GPUVertex(CGPoint(x: x + 0.014, y: y + 0.025), color)
                ], primitive: .lineStrip, encoder: encoder)
            case .desert:
                let color = GPUColor(0.76, 0.38, 0.14, 0.58)
                let y = 0.76 + variant * 0.05
                submit([
                    GPUVertex(CGPoint(x: x - 0.075, y: y), color),
                    GPUVertex(CGPoint(x: x, y: y - 0.016), color),
                    GPUVertex(CGPoint(x: x + 0.075, y: y), color)
                ], primitive: .lineStrip, encoder: encoder)
            case .ocean:
                let color = GPUColor(0.82, 0.96, 1, 0.35)
                let y = 0.70 + variant * 0.07
                rectangle(center: CGPoint(x: x, y: y), size: CGSize(width: 0.13, height: 0.008), color: color, encoder: encoder)
            case .moon:
                let y = 0.81 + variant * 0.035
                circle(center: CGPoint(x: x, y: y), radius: 0.018 + variant * 0.003, color: GPUColor(0.34, 0.34, 0.45, 0.75), segments: 14, encoder: encoder)
            }
        }
    }

    /// Procedurally animates the selected optional effect. Effects are Play-only and Clear produces
    /// no particles, so rain/snow/clouds/wind never appear merely because the app is open.
    private func drawWeather(_ weather: SceneWeather, encoder: MTLRenderCommandEncoder) {
        guard isPlaying, weather != .clear else { return }
        let time = animationTime

        if weather == .cloudy {
            for seed in 0..<7 {
                let speed = 0.018 + Double(seed % 3) * 0.006
                let x = positiveRemainder(Double(seed) * 0.23 + time * speed, modulus: 1.35) - 0.17
                let y = 0.12 + Double((seed * 37) % 30) / 100
                drawCloud(center: CGPoint(x: x, y: y), scale: 0.75 + Double(seed % 3) * 0.15, encoder: encoder)
            }
            return
        }

        if weather == .windy {
            for seed in 0..<18 {
                let x = positiveRemainder(Double(seed) * 0.19 + time * (0.22 + Double(seed % 4) * 0.025), modulus: 1.25) - 0.12
                let y = 0.16 + Double((seed * 47) % 72) / 100
                let length = 0.07 + Double(seed % 4) * 0.018
                let color = GPUColor(0.92, 0.98, 1, 0.68)
                submit([
                    GPUVertex(CGPoint(x: x, y: y), color),
                    GPUVertex(CGPoint(x: x + length * 0.55, y: y - 0.008), color),
                    GPUVertex(CGPoint(x: x + length, y: y + 0.006), color)
                ], primitive: .lineStrip, encoder: encoder)
            }
            return
        }

        // Stable integer seeds make particle positions deterministic and allocation-free per frame.
        for seed in 0..<54 {
            let startX = Double((seed * 43 + 17) % 101) / 100
            let startY = Double((seed * 71 + 9) % 103) / 100
            switch weather {
            case .clear:
                break
            case .rain:
                let y = positiveRemainder(startY + time * (0.55 + Double(seed % 5) * 0.035), modulus: 1.08) - 0.04
                let x = positiveRemainder(startX - time * 0.08, modulus: 1.04) - 0.02
                let color = GPUColor(0.72, 0.88, 1, 0.72)
                submit([
                    GPUVertex(CGPoint(x: x, y: y), color),
                    GPUVertex(CGPoint(x: x - 0.012, y: y + 0.045), color)
                ], primitive: .line, encoder: encoder)
            case .snow:
                let drift = sin(time * 1.4 + Double(seed)) * 0.025
                let x = positiveRemainder(startX + drift, modulus: 1.02) - 0.01
                let y = positiveRemainder(startY + time * (0.10 + Double(seed % 4) * 0.012), modulus: 1.04) - 0.02
                circle(
                    center: CGPoint(x: x, y: y),
                    radius: seed.isMultiple(of: 3) ? 0.006 : 0.004,
                    color: GPUColor(1, 1, 1, 0.86),
                    segments: 8,
                    encoder: encoder
                )
            case .cloudy, .windy:
                break
            }
        }
    }

    /// Builds a soft cloud from overlapping alpha-blended primitives.
    private func drawCloud(center: CGPoint, scale: Double, encoder: MTLRenderCommandEncoder) {
        let shadow = GPUColor(0.70, 0.76, 0.84, 0.82)
        let highlight = GPUColor(0.88, 0.91, 0.95, 0.92)
        rectangle(
            center: CGPoint(x: center.x, y: center.y + 0.018 * scale),
            size: CGSize(width: 0.16 * scale, height: 0.045 * scale),
            color: shadow,
            encoder: encoder
        )
        circle(center: CGPoint(x: center.x - 0.045 * scale, y: center.y), radius: 0.035 * scale, color: highlight, segments: 18, encoder: encoder)
        circle(center: CGPoint(x: center.x, y: center.y - 0.018 * scale), radius: 0.050 * scale, color: highlight, segments: 20, encoder: encoder)
        circle(center: CGPoint(x: center.x + 0.050 * scale, y: center.y + 0.002 * scale), radius: 0.032 * scale, color: highlight, segments: 18, encoder: encoder)
    }

    /// Unlike Swift's remainder operator, always returns a value in `0..<modulus` for valid input.
    /// This is needed when the child pans left and when particles wrap across an edge.
    private func positiveRemainder(_ value: Double, modulus: Double) -> Double {
        guard modulus > 0 else { return value }
        let result = value.truncatingRemainder(dividingBy: modulus)
        return result >= 0 ? result : result + modulus
    }

    /// Draws a lightweight bounding rectangle around the Build-mode selection.
    private func drawSelection(around item: WorldItem, encoder: MTLRenderCommandEncoder) {
        let halfWidth = 0.095 * item.scale
        let halfHeight = halfWidth * pixelAspect
        let color = GPUColor(1, 1, 1, 0.92)
        let points = [
            CGPoint(x: item.x - halfWidth, y: item.y - halfHeight),
            CGPoint(x: item.x + halfWidth, y: item.y - halfHeight),
            CGPoint(x: item.x + halfWidth, y: item.y + halfHeight),
            CGPoint(x: item.x - halfWidth, y: item.y + halfHeight),
            CGPoint(x: item.x - halfWidth, y: item.y - halfHeight)
        ]
        submit(points.map { GPUVertex($0, color) }, primitive: .lineStrip, encoder: encoder)
    }

    /// Maps saved world-space stroke x coordinates through the current camera before submission.
    private func polyline(_ points: [NormalizedPoint], color: GPUColor, encoder: MTLRenderCommandEncoder) {
        guard points.count > 1 else { return }
        submit(points.map { GPUVertex(CGPoint(x: screenX($0.x), y: $0.y), color) }, primitive: .lineStrip, encoder: encoder)
    }

    // MARK: - Primitive construction

    /// Emits a rectangle as two triangles because Metal has no rectangle primitive.
    private func rectangle(center: CGPoint, size: CGSize, color: GPUColor, encoder: MTLRenderCommandEncoder) {
        let x = center.x, y = center.y, w = size.width / 2, h = size.height / 2
        submit([
            GPUVertex(CGPoint(x: x-w, y: y-h), color), GPUVertex(CGPoint(x: x+w, y: y-h), color), GPUVertex(CGPoint(x: x-w, y: y+h), color),
            GPUVertex(CGPoint(x: x+w, y: y-h), color), GPUVertex(CGPoint(x: x+w, y: y+h), color), GPUVertex(CGPoint(x: x-w, y: y+h), color)
        ], primitive: .triangle, encoder: encoder)
    }

    private func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ color: GPUColor, _ encoder: MTLRenderCommandEncoder) {
        submit([GPUVertex(a, color), GPUVertex(b, color), GPUVertex(c, color)], primitive: .triangle, encoder: encoder)
    }

    /// Approximates a circle with a configurable triangle fan; y is aspect-corrected.
    private func circle(center: CGPoint, radius: Double, color: GPUColor, segments: Int = 28, encoder: MTLRenderCommandEncoder) {
        var vertices: [GPUVertex] = []
        for index in 0..<segments {
            let firstAngle = Double(index) / Double(segments) * Double.pi * 2
            let secondAngle = Double(index + 1) / Double(segments) * Double.pi * 2
            vertices.append(GPUVertex(center, color))
            vertices.append(GPUVertex(CGPoint(x: center.x + cos(firstAngle) * radius, y: center.y + sin(firstAngle) * radius * pixelAspect), color))
            vertices.append(GPUVertex(CGPoint(x: center.x + cos(secondAngle) * radius, y: center.y + sin(secondAngle) * radius * pixelAspect), color))
        }
        submit(vertices, primitive: .triangle, encoder: encoder)
    }

    /// Uploads a transient vertex array and records one draw call in the active command encoder.
    private func submit(_ vertices: [GPUVertex], primitive: MTLPrimitiveType, encoder: MTLRenderCommandEncoder) {
        guard let device, !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<GPUVertex>.stride * vertices.count) else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    private func terrainBackground(_ terrain: Terrain) -> GPUColor {
        switch terrain {
        case .meadow: GPUColor(0.46, 0.78, 0.94)
        case .desert: GPUColor(0.97, 0.72, 0.40)
        case .ocean: GPUColor(0.05, 0.39, 0.72)
        case .moon: GPUColor(0.12, 0.13, 0.27)
        }
    }
}

/// Coarse rig families used to give different animal bodies plausible motion.
private enum AnimalMotionStyle {
    case quadruped
    case walker
    case flyer
    case swimmer
    case hopper
    case crawler
    case still
}

/// CPU representation matching the `Vertex` layout in the embedded Metal shader.
/// Explicit padding aligns the color SIMD value to the layout Metal expects.
private struct GPUVertex {
    var position: SIMD2<Float>
    var padding = SIMD2<Float>(repeating: 0)
    var color: SIMD4<Float>

    init(_ point: CGPoint, _ color: GPUColor) {
        position = SIMD2(Float(point.x), Float(point.y))
        self.color = SIMD4(color.r, color.g, color.b, color.a)
    }
}

/// Vertex layout for a textured rectangle, pairing normalized position with UV coordinates.
private struct TextureVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>

    init(_ point: CGPoint, _ uv: SIMD2<Float>) {
        position = SIMD2(Float(point.x), Float(point.y))
        self.uv = uv
    }
}

/// Small renderer-native RGBA value that avoids bridging UIColor for every primitive and frame.
struct GPUColor {
    let r: Float
    let g: Float
    let b: Float
    let a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: String) {
        // Catalog colors use six-digit RGB. Invalid input intentionally becomes black.
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        r = Float((value >> 16) & 0xff) / 255
        g = Float((value >> 8) & 0xff) / 255
        b = Float(value & 0xff) / 255
        a = 1
    }
}

/// Retained for UIKit image-rasterization call sites that need the same catalog hex convention.
private extension UIColor {
    convenience init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
