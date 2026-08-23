# Q3BSPViewer (iOS)

A Metal/Swift port of the Direct3D9 Quake 3 BSP viewer in `../q3bsp-win`.
Loads `q3dm1.bsp`, walks the BSP tree each frame to compute the potentially
visible face set (PVS) from the camera position, and renders it with
per-vertex lighting (global ambient + 2 point lights) — same as the original,
no textures are bound; only vertex color and lighting matter.

## Source mapping

| Windows original | iOS port |
|---|---|
| `q3bsp_viewer.cpp` (`WinMain`/`WindowProc`/`ProcessKeys`) | `App/GameViewController.swift`, `App/TouchControlsView.swift` |
| `Renderer.h/.cpp` | `Renderer/Renderer.swift`, `Renderer/Shaders.metal` |
| `Camera.h/.cpp` | `Renderer/Camera.swift` |
| `q3map.h/.cpp` | `Renderer/BSPMap.swift` |

## Controls

- **Left side drag** — floating joystick: move forward/back/strafe.
- **Right side drag** — floating joystick: look (yaw/pitch).
- **Fire** button — ray-test from the camera along its look vector, paints
  the hit triangle green (replaces left-click/`F`).
- **Wire** button — toggle wireframe fill mode (replaces `I`).

## Build

```
xcodegen generate
xcodebuild -scheme Q3BSPViewer -destination 'generic/platform=iOS' build
```
