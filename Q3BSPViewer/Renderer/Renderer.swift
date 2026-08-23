import MetalKit
import simd

private struct PointLightConfig {
    let position: SIMD3<Float>
    let range: Float
    let color: SIMD3<Float>
    let attenuation0: Float
}

final class Renderer: NSObject, MTKViewDelegate {

    let camera: Camera
    private let map = BSPMap()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var uniformBuffer: MTLBuffer!

    private var aspect: Float = 1
    private var wireframe = false

    // Set by touch input each frame; x = strafe, y = forward for moveInput,
    // x = yaw rate, y = pitch rate for lookInput. Mirrors ProcessKeys applying
    // a fixed speed per frame while a key/joystick is held.
    var moveInput: SIMD2<Float> = .zero
    var lookInput: SIMD2<Float> = .zero

    // q3dm1-specific spawn point and point lights, matching Renderer::InitD3D.
    // These are already expressed in the target left-handed coordinate space
    // (same convention q3map's swizzle produces), so no swizzle is applied here.
    private static let initialCameraPosition = SIMD3<Float>(675, 80, -2060)
    private let lights = [
        PointLightConfig(position: SIMD3<Float>(675, 80, -2060), range: 1000, color: SIMD3<Float>(1, 1, 1), attenuation0: 0.5),
        PointLightConfig(position: SIMD3<Float>(675, 80, -645), range: 1000, color: SIMD3<Float>(1, 1, 1), attenuation0: 0.5),
    ]
    private static let ambientColor = SIMD3<Float>(20, 20, 20) / 255.0

    private static let uniformsStride = 144 // matches SceneUniforms in Shaders.metal

    init?(mtkView: MTKView) {
        guard let device = mtkView.device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.camera = Camera(startPosition: Renderer.initialCameraPosition)
        super.init()

        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 192.0 / 255.0, green: 192.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)

        guard map.loadMap(resourceName: "q3dm1", device: device) else { return nil }
        guard buildPipeline(colorFormat: mtkView.colorPixelFormat, depthFormat: mtkView.depthStencilPixelFormat) else { return nil }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        uniformBuffer = device.makeBuffer(length: Renderer.uniformsStride, options: .storageModeShared)
    }

    private func buildPipeline(colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> Bool {
        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "q3_vertex_main"),
              let fragmentFn = library.makeFunction(name: "q3_fragment_main") else { return false }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = MemoryLayout<Q3Vertex>.offset(of: \.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<Q3Vertex>.offset(of: \.normal)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<Q3Vertex>.offset(of: \.color)!
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float2
        vertexDescriptor.attributes[3].offset = MemoryLayout<Q3Vertex>.offset(of: \.texCoord)!
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.attributes[4].format = .float2
        vertexDescriptor.attributes[4].offset = MemoryLayout<Q3Vertex>.offset(of: \.lightmapCoord)!
        vertexDescriptor.attributes[4].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Q3Vertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat

        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        return pipelineState != nil
    }

    func toggleWireframe() { wireframe.toggle() }

    func rayTest() {
        map.rayTest(origin: camera.position, direction: camera.look)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        if moveInput.y != 0 { camera.moveForward(CAM_MOVE_SPEED * moveInput.y) }
        if moveInput.x != 0 { camera.moveRight(CAM_MOVE_SPEED * moveInput.x) }
        if lookInput.x != 0 { camera.addYaw(CAM_ROT_SPEED_TOUCH * lookInput.x) }
        if lookInput.y != 0 { camera.addPitch(CAM_ROT_SPEED_TOUCH * lookInput.y) }

        map.buildVis(cameraPosition: camera.position)

        let viewMatrix = camera.calculateViewMatrix()
        let projMatrix = float4x4.perspectiveLH(fovY: .pi / 4, aspect: aspect, nearZ: 1, farZ: 3000)
        let viewProjection = projMatrix * viewMatrix

        writeUniforms(viewProjection: viewProjection)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)

        map.drawMap(encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func writeUniforms(viewProjection: float4x4) {
        let ptr = uniformBuffer.contents()
        ptr.storeBytes(of: viewProjection, toByteOffset: 0, as: float4x4.self)
        ptr.storeBytes(of: Renderer.ambientColor.x, toByteOffset: 64, as: Float.self)
        ptr.storeBytes(of: Renderer.ambientColor.y, toByteOffset: 68, as: Float.self)
        ptr.storeBytes(of: Renderer.ambientColor.z, toByteOffset: 72, as: Float.self)
        ptr.storeBytes(of: UInt32(lights.count), toByteOffset: 76, as: UInt32.self)
        for (i, light) in lights.enumerated() {
            let base = 80 + i * 32
            ptr.storeBytes(of: light.position.x, toByteOffset: base + 0, as: Float.self)
            ptr.storeBytes(of: light.position.y, toByteOffset: base + 4, as: Float.self)
            ptr.storeBytes(of: light.position.z, toByteOffset: base + 8, as: Float.self)
            ptr.storeBytes(of: light.range, toByteOffset: base + 12, as: Float.self)
            ptr.storeBytes(of: light.color.x, toByteOffset: base + 16, as: Float.self)
            ptr.storeBytes(of: light.color.y, toByteOffset: base + 20, as: Float.self)
            ptr.storeBytes(of: light.color.z, toByteOffset: base + 24, as: Float.self)
            ptr.storeBytes(of: light.attenuation0, toByteOffset: base + 28, as: Float.self)
        }
    }
}
