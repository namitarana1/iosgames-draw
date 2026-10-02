# Drawtopia

Drawtopia is a native iPhone and iPad creative-world prototype for children ages 9–12. The world viewport is rendered with Apple's Metal framework, while SwiftUI provides the adaptive editing controls.

## Current prototype

- Freehand drawing with seven colors and undo
- 300 searchable construction shapes across 17 categories
- Drawing recognition with coherent replacement suggestions
- Named custom shapes saved locally under My Shapes and used in future matching
- Meadow, desert, ocean, and moon landscapes
- Erase and clear-world tools
- Play mode with a draggable explorer
- Automatic local saving between launches
- Immersive edge-to-edge iPhone and iPad layout

## Run it

1. Open `Drawtopia.xcodeproj` in Xcode.
2. Select an iPhone or iPad simulator.
3. Press Run.

The project targets iOS 17 or newer and has no third-party dependencies.

## Architecture

- `MetalWorldView.swift`: Metal renderer and procedural world art
- `WorldCanvasView.swift`: touch interaction and editing gestures
- `Models.swift`: codable world, drawing, terrain, and item models
- `WorldStore.swift`: local persistence and world mutations
- `ContentView.swift`: adaptive creator and play-mode interface

The renderer is deliberately isolated from the game model. Future iterations can add textures, animation, physics, cameras, and 3D meshes without replacing the editor or save format.
