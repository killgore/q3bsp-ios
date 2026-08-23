import Metal
import simd

// Vertex layout used for the Metal vertex buffer. Field order mirrors the
// original BSPD3DVertex (position, normal, color, texcoord, lightmapcoord);
// texcoord/lightmapcoord are carried through but never sampled since the
// original never binds a texture either (SetTexture(0, NULL)).
struct Q3Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var lightmapCoord: SIMD2<Float>
}

private extension Data {
    func i32(_ offset: Int) -> Int32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }
    func f32(_ offset: Int) -> Float {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }
    func u8(_ offset: Int) -> UInt8 {
        self[offset]
    }
}

final class BSPMap {

    // Lump indices, in file order - matches q3map::eLumps.
    private enum Lump: Int {
        case entities = 0, textures, planes, nodes, leaves, leafFaces, leafBrushes,
             models, brushes, brushSides, vertices, meshVerts, shaders, faces,
             lightMaps, lightVolumes, visData
        static let count = 17
    }

    private struct BSPPlane { var normal: SIMD3<Float>; var d: Float }
    private struct BSPNode { var plane: Int32; var front: Int32; var back: Int32; var mins: SIMD3<Int32>; var maxs: SIMD3<Int32> }
    private struct BSPLeaf {
        var cluster: Int32; var area: Int32
        var mins: SIMD3<Int32>; var maxs: SIMD3<Int32>
        var leafFirstFace: Int32; var leafFaceCount: Int32
        var leafBrush: Int32; var numOfLeafBrushes: Int32
    }
    private struct BSPFace { var vertexIndex: Int32; var meshVertIndex: Int32; var numMeshVerts: Int32 }

    private var planes: [BSPPlane] = []
    private var nodes: [BSPNode] = []
    private var leaves: [BSPLeaf] = []
    private var leafFaces: [Int32] = []
    private var meshVerts: [Int32] = []
    private var faces: [BSPFace] = []

    private var visNumClusters: Int32 = 0
    private var visBytesPerCluster: Int32 = 0
    private var visBitsets: [UInt8] = []

    private var vertices: [Q3Vertex] = []
    private var vertexBuffer: MTLBuffer?
    private var faceIndexBuffers: [MTLBuffer?] = []
    private var faceIndexes: [[UInt32]] = []

    private var visibleLeaves: [Int] = []
    private var visibleFaces: [Int] = []

    var numVertices: Int { vertices.count }

    // MARK: - Load

    func loadMap(resourceName: String, device: MTLDevice) -> Bool {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "bsp"),
              let data = try? Data(contentsOf: url) else {
            assertionFailure("Could not load \(resourceName).bsp from bundle")
            return false
        }

        // Header: 4-byte magic + int version.
        var lumpOffsets: [(offset: Int, length: Int)] = []
        let lumpDirBase = 8
        for i in 0..<Lump.count {
            let base = lumpDirBase + i * 8
            lumpOffsets.append((Int(data.i32(base)), Int(data.i32(base + 4))))
        }

        planes = readArray(data, lumpOffsets[Lump.planes.rawValue], stride: 16) { d, o in
            BSPPlane(normal: SIMD3<Float>(d.f32(o), d.f32(o + 4), d.f32(o + 8)), d: d.f32(o + 12))
        }

        nodes = readArray(data, lumpOffsets[Lump.nodes.rawValue], stride: 36) { d, o in
            BSPNode(plane: d.i32(o), front: d.i32(o + 4), back: d.i32(o + 8),
                    mins: SIMD3<Int32>(d.i32(o + 12), d.i32(o + 16), d.i32(o + 20)),
                    maxs: SIMD3<Int32>(d.i32(o + 24), d.i32(o + 28), d.i32(o + 32)))
        }

        leaves = readArray(data, lumpOffsets[Lump.leaves.rawValue], stride: 48) { d, o in
            BSPLeaf(cluster: d.i32(o), area: d.i32(o + 4),
                    mins: SIMD3<Int32>(d.i32(o + 8), d.i32(o + 12), d.i32(o + 16)),
                    maxs: SIMD3<Int32>(d.i32(o + 20), d.i32(o + 24), d.i32(o + 28)),
                    leafFirstFace: d.i32(o + 32), leafFaceCount: d.i32(o + 36),
                    leafBrush: d.i32(o + 40), numOfLeafBrushes: d.i32(o + 44))
        }

        leafFaces = readArray(data, lumpOffsets[Lump.leafFaces.rawValue], stride: 4) { d, o in d.i32(o) }
        meshVerts = readArray(data, lumpOffsets[Lump.meshVerts.rawValue], stride: 4) { d, o in d.i32(o) }

        faces = readArray(data, lumpOffsets[Lump.faces.rawValue], stride: 104) { d, o in
            BSPFace(vertexIndex: d.i32(o + 12), meshVertIndex: d.i32(o + 20), numMeshVerts: d.i32(o + 24))
        }

        let (visOffset, _) = lumpOffsets[Lump.visData.rawValue]
        visNumClusters = data.i32(visOffset)
        visBytesPerCluster = data.i32(visOffset + 4)
        let clusterDataSize = Int(visNumClusters * visBytesPerCluster)
        if clusterDataSize > 0 {
            visBitsets = (0..<clusterDataSize).map { data.u8(visOffset + 8 + $0) }
        }

        loadVertices(data, lump: lumpOffsets[Lump.vertices.rawValue])
        swizzleForMetal()

        guard buildVertexBuffer(device: device) else { return false }
        guard createIndexBuffers(device: device) else { return false }

        return true
    }

    private func readArray<T>(_ data: Data, _ lump: (offset: Int, length: Int), stride: Int, _ make: (Data, Int) -> T) -> [T] {
        let count = lump.length / stride
        var result: [T] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(make(data, lump.offset + i * stride))
        }
        return result
    }

    private func loadVertices(_ data: Data, lump: (offset: Int, length: Int)) {
        // Source BSPVertex layout: pos[3]f, texcoord[2]f, lightmapcoord[2]f, normal[3]f, color[4]ub - 44 bytes.
        let stride = 44
        let count = lump.length / stride
        vertices.reserveCapacity(count)
        for i in 0..<count {
            let o = lump.offset + i * stride
            let position = SIMD3<Float>(data.f32(o), data.f32(o + 4), data.f32(o + 8))
            let texCoord = SIMD2<Float>(data.f32(o + 12), data.f32(o + 16))
            let lmCoord = SIMD2<Float>(data.f32(o + 20), data.f32(o + 24))
            let normal = SIMD3<Float>(data.f32(o + 28), data.f32(o + 32), data.f32(o + 36))
            let color = SIMD4<Float>(Float(data.u8(o + 40)) / 255.0,
                                      Float(data.u8(o + 41)) / 255.0,
                                      Float(data.u8(o + 42)) / 255.0,
                                      Float(data.u8(o + 43)) / 255.0)
            vertices.append(Q3Vertex(position: position, normal: normal, color: color,
                                      texCoord: texCoord, lightmapCoord: lmCoord))
        }
    }

    // Ported from q3map::swizzle / convertCoordForD3D - converts the Quake 3
    // coordinate system to the left-handed system used by the view/projection
    // matrices in Camera/Renderer.
    private func swizzleForMetal() {
        for i in 0..<vertices.count {
            vertices[i].position = swizzle(vertices[i].position)
            vertices[i].normal = swizzle(vertices[i].normal)
        }
        for i in 0..<planes.count {
            planes[i].normal = swizzle(planes[i].normal)
        }
        for i in 0..<nodes.count {
            nodes[i].mins = swizzleI(nodes[i].mins)
            nodes[i].maxs = swizzleI(nodes[i].maxs)
        }
        for i in 0..<leaves.count {
            leaves[i].mins = swizzleI(leaves[i].mins)
            leaves[i].maxs = swizzleI(leaves[i].maxs)
        }
    }

    private func swizzle(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, v.z, -v.y) }
    private func swizzleI(_ v: SIMD3<Int32>) -> SIMD3<Int32> { SIMD3<Int32>(v.x, v.z, -v.y) }

    private func buildVertexBuffer(device: MTLDevice) -> Bool {
        let length = MemoryLayout<Q3Vertex>.stride * vertices.count
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return false }
        buffer.contents().assumingMemoryBound(to: Q3Vertex.self).update(from: vertices, count: vertices.count)
        vertexBuffer = buffer
        return true
    }

    private func createIndexBuffers(device: MTLDevice) -> Bool {
        faceIndexBuffers.reserveCapacity(faces.count)
        faceIndexes.reserveCapacity(faces.count)

        for face in faces {
            guard face.numMeshVerts > 0 else {
                faceIndexBuffers.append(nil)
                faceIndexes.append([])
                continue
            }

            var indices: [UInt32] = []
            indices.reserveCapacity(Int(face.numMeshVerts))
            for j in 0..<Int(face.numMeshVerts) {
                let mv = Int(face.meshVertIndex) + j
                let offset = UInt32(Int(face.vertexIndex) + Int(meshVerts[mv]))
                indices.append(offset)
            }

            guard let buffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
                return false
            }
            faceIndexBuffers.append(buffer)
            faceIndexes.append(indices)
        }
        return true
    }

    // MARK: - Visibility (PVS)

    func buildVis(cameraPosition: SIMD3<Float>) {
        let cameraLeaf = findLeaf(cameraPosition)
        visibleLeaves.removeAll(keepingCapacity: true)
        visibleFaces.removeAll(keepingCapacity: true)
        findVisibleLeaves(cameraLeaf)
        findVisibleFaces()
    }

    private func findLeaf(_ cameraPos: SIMD3<Float>) -> Int {
        var index = 0
        while index >= 0 {
            let node = nodes[index]
            let plane = planes[Int(node.plane)]
            let distance = simd_dot(plane.normal, cameraPos) - plane.d
            index = distance >= 0 ? Int(node.front) : Int(node.back)
        }
        return -index - 1
    }

    private func findVisibleLeaves(_ cameraLeaf: Int) {
        let camCluster = leaves[cameraLeaf].cluster
        for i in 0..<leaves.count {
            if isClusterVisible(currentCluster: camCluster, testCluster: leaves[i].cluster) {
                visibleLeaves.append(i)
            }
        }
    }

    private func isClusterVisible(currentCluster: Int32, testCluster: Int32) -> Bool {
        if visBitsets.isEmpty || currentCluster < 0 { return true }
        let i = Int(currentCluster * visBytesPerCluster) + Int(testCluster >> 3)
        let visSet = visBitsets[i]
        return (visSet & (1 << (testCluster & 7))) != 0
    }

    private func findVisibleFaces() {
        var seen = Set<Int>()
        for leafIndex in visibleLeaves {
            let leaf = leaves[leafIndex]
            for f in 0..<Int(leaf.leafFaceCount) {
                let faceIndex = Int(leafFaces[Int(leaf.leafFirstFace) + f])
                if seen.insert(faceIndex).inserted {
                    visibleFaces.append(faceIndex)
                }
            }
        }
    }

    // MARK: - Draw

    func drawMap(encoder: MTLRenderCommandEncoder) {
        guard let vb = vertexBuffer else { return }
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        for faceIndex in visibleFaces {
            guard let ib = faceIndexBuffers[faceIndex] else { continue }
            let indexCount = faceIndexes[faceIndex].count
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                           indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        }
    }

    // MARK: - Ray test (Moller-Trumbore), ported from q3map::RayTest.

    func rayTest(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        var hit = false
        var closest: Float = 0
        var targetFace = (0, 0, 0)

        for faceIndex in visibleFaces {
            let indices = faceIndexes[faceIndex]
            var j = 0
            while j + 2 < indices.count {
                let i0 = Int(indices[j]), i1 = Int(indices[j + 1]), i2 = Int(indices[j + 2])
                j += 3

                let v0 = vertices[i0].position, v1 = vertices[i1].position, v2 = vertices[i2].position
                let e1 = v1 - v0
                let e2 = v2 - v0

                let p = simd_cross(direction, e2)
                let a = simd_dot(e1, p)
                if a == 0 { continue }
                let f = 1.0 / a

                let s = origin - v0
                let u = f * simd_dot(s, p)
                if u < 0 || u > 1 { continue }

                let q = simd_cross(s, e1)
                let v = f * simd_dot(direction, q)
                if v < 0 || (u + v) > 1 { continue }

                let t = f * simd_dot(e2, q)
                if t >= 0 && (!hit || t < closest) {
                    targetFace = (i0, i1, i2)
                    hit = true
                    closest = t
                }
            }
        }

        guard hit, let vb = vertexBuffer else { return }
        let hitColor = SIMD4<Float>(0, 1, 0, 1)
        vertices[targetFace.0].color = hitColor
        vertices[targetFace.1].color = hitColor
        vertices[targetFace.2].color = hitColor

        let ptr = vb.contents().assumingMemoryBound(to: Q3Vertex.self)
        ptr[targetFace.0].color = hitColor
        ptr[targetFace.1].color = hitColor
        ptr[targetFace.2].color = hitColor
    }
}
