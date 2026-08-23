import UIKit
import simd

protocol TouchControlsDelegate: AnyObject {
    func touchControls(_ view: TouchControlsView, didUpdateMove displacement: SIMD2<Float>)
    func touchControls(_ view: TouchControlsView, didUpdateLook displacement: SIMD2<Float>)
    func touchControlsFireTapped(_ view: TouchControlsView)
    func touchControlsWireframeTapped(_ view: TouchControlsView)
}

// Replaces WASD/arrow-key movement and mouse-look from the Windows original
// with a pair of floating virtual joysticks: a touch starting in the left
// half drives movement, a touch starting in the right half drives look.
// Both can be held at once. Fire/Wireframe buttons replace the left-click/F
// ray test and the 'I' wireframe toggle.
final class TouchControlsView: UIView {

    weak var delegate: TouchControlsDelegate?

    private let maxRadius: CGFloat = 55

    private var moveTouch: UITouch?
    private var moveAnchor: CGPoint = .zero
    private let moveBase = JoystickIndicatorLayer(isKnob: false)
    private let moveKnob = JoystickIndicatorLayer(isKnob: true)

    private var lookTouch: UITouch?
    private var lookAnchor: CGPoint = .zero
    private let lookBase = JoystickIndicatorLayer(isKnob: false)
    private let lookKnob = JoystickIndicatorLayer(isKnob: true)

    let fireButton = UIButton(type: .system)
    let wireframeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        [moveBase, moveKnob, lookBase, lookKnob].forEach { layer.addSublayer($0) }

        configureButton(fireButton, title: "Fire")
        configureButton(wireframeButton, title: "Wire")
        addSubview(fireButton)
        addSubview(wireframeButton)
        fireButton.addTarget(self, action: #selector(fireTapped), for: .touchUpInside)
        wireframeButton.addTarget(self, action: #selector(wireframeTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.25)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        button.configuration = config
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin: CGFloat = 24
        let buttonSize = CGSize(width: 84, height: 44)
        fireButton.frame = CGRect(
            x: bounds.width - margin - buttonSize.width,
            y: bounds.height - margin - buttonSize.height,
            width: buttonSize.width, height: buttonSize.height)
        wireframeButton.frame = CGRect(
            x: bounds.width - margin - buttonSize.width,
            y: fireButton.frame.minY - 12 - buttonSize.height,
            width: buttonSize.width, height: buttonSize.height)
    }

    @objc private func fireTapped() { delegate?.touchControlsFireTapped(self) }
    @objc private func wireframeTapped() { delegate?.touchControlsWireframeTapped(self) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if fireButton.frame.contains(point) || wireframeButton.frame.contains(point) { continue }

            if point.x < bounds.midX {
                guard moveTouch == nil else { continue }
                moveTouch = touch
                moveAnchor = point
                show(base: moveBase, knob: moveKnob, at: point)
            } else {
                guard lookTouch == nil else { continue }
                lookTouch = touch
                lookAnchor = point
                show(base: lookBase, knob: lookKnob, at: point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == moveTouch {
                let displacement = knobDisplacement(for: touch, anchor: moveAnchor, knob: moveKnob)
                delegate?.touchControls(self, didUpdateMove: displacement)
            } else if touch == lookTouch {
                let displacement = knobDisplacement(for: touch, anchor: lookAnchor, knob: lookKnob)
                delegate?.touchControls(self, didUpdateLook: displacement)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch == moveTouch {
                moveTouch = nil
                hide(base: moveBase, knob: moveKnob)
                delegate?.touchControls(self, didUpdateMove: .zero)
            } else if touch == lookTouch {
                lookTouch = nil
                hide(base: lookBase, knob: lookKnob)
                delegate?.touchControls(self, didUpdateLook: .zero)
            }
        }
    }

    private func show(base: CALayer, knob: CALayer, at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.position = point
        base.opacity = 1
        knob.position = point
        knob.opacity = 1
        CATransaction.commit()
    }

    private func hide(base: CALayer, knob: CALayer) {
        base.opacity = 0
        knob.opacity = 0
    }

    private func knobDisplacement(for touch: UITouch, anchor: CGPoint, knob: CALayer) -> SIMD2<Float> {
        let point = touch.location(in: self)
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        let dist = min(sqrt(dx * dx + dy * dy), maxRadius)
        if dist > 0 {
            let angle = atan2(dy, dx)
            dx = cos(angle) * dist
            dy = sin(angle) * dist
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.position = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        CATransaction.commit()
        return SIMD2<Float>(Float(dx / maxRadius), Float(dy / maxRadius))
    }
}

final class JoystickIndicatorLayer: CAShapeLayer {
    init(isKnob: Bool) {
        super.init()
        let radius: CGFloat = isKnob ? 24 : 55
        bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        path = UIBezierPath(ovalIn: bounds).cgPath
        fillColor = UIColor.white.withAlphaComponent(isKnob ? 0.45 : 0.15).cgColor
        strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
        lineWidth = isKnob ? 0 : 1
        opacity = 0
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
