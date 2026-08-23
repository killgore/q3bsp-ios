import simd

let CAM_MOVE_SPEED: Float = 10.0
let CAM_ROT_SPEED_TOUCH: Float = 0.03

final class Camera {
    private(set) var position: SIMD3<Float>
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    private(set) var roll: Float = 0

    private(set) var up = SIMD3<Float>(0, 1, 0)
    private(set) var look = SIMD3<Float>(0, 0, 1)
    private(set) var right = SIMD3<Float>(1, 0, 0)

    init(startPosition: SIMD3<Float>) {
        position = startPosition
    }

    func moveForward(_ amount: Float) { position += look * amount }
    func moveRight(_ amount: Float) { position += right * amount }
    func moveUp(_ amount: Float) { position += up * amount }

    func addYaw(_ amount: Float) { yaw = restrictAngleTo360(yaw + amount) }
    func addPitch(_ amount: Float) { pitch = restrictAngleTo360(pitch + amount) }
    func addRoll(_ amount: Float) { roll = restrictAngleTo360(roll + amount) }

    private func restrictAngleTo360(_ angle: Float) -> Float {
        var a = angle
        while a > 2 * Float.pi { a -= 2 * Float.pi }
        while a < 0 { a += 2 * Float.pi }
        return a
    }

    // Ported from Camera::CalculateViewMatrix - builds axes from yaw/pitch/roll
    // and packs them into a left-handed view matrix (D3D9-style row layout).
    func calculateViewMatrix() -> float4x4 {
        up = SIMD3<Float>(0, 1, 0)
        look = SIMD3<Float>(0, 0, 1)
        right = SIMD3<Float>(1, 0, 0)

        let yawMatrix = float4x4(rotationAxis: up, angle: yaw)
        look = yawMatrix.transformDirection(look)
        right = yawMatrix.transformDirection(right)

        let pitchMatrix = float4x4(rotationAxis: right, angle: pitch)
        look = pitchMatrix.transformDirection(look)
        up = pitchMatrix.transformDirection(up)

        let rollMatrix = float4x4(rotationAxis: look, angle: roll)
        right = rollMatrix.transformDirection(right)
        up = rollMatrix.transformDirection(up)

        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right.x, up.x, look.x, 0)
        m.columns.1 = SIMD4<Float>(right.y, up.y, look.y, 0)
        m.columns.2 = SIMD4<Float>(right.z, up.z, look.z, 0)
        m.columns.3 = SIMD4<Float>(-simd_dot(position, right),
                                    -simd_dot(position, up),
                                    -simd_dot(position, look),
                                    1)
        return m
    }
}

extension float4x4 {
    // Rotation about an arbitrary axis, matching D3DXMatrixRotationAxis.
    init(rotationAxis axis: SIMD3<Float>, angle: Float) {
        let a = simd_normalize(axis)
        let c = cos(angle)
        let s = sin(angle)
        let t = 1 - c
        self.init(columns: (
            SIMD4<Float>(t * a.x * a.x + c,       t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y, 0),
            SIMD4<Float>(t * a.x * a.y - s * a.z, t * a.y * a.y + c,       t * a.y * a.z + s * a.x, 0),
            SIMD4<Float>(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c,       0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    func transformDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4<Float>(v, 0)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    // Left-handed perspective projection, matching D3DXMatrixPerspectiveFovLH
    // (NDC z in [0,1], same convention Metal's clip space uses).
    static func perspectiveLH(fovY: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (farZ - nearZ)
        return float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, 1),
            SIMD4<Float>(0, 0, -nearZ * zScale, 0)
        ))
    }
}
