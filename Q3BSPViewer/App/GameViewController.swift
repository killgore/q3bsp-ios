import UIKit
import MetalKit
import simd

final class GameViewController: UIViewController, TouchControlsDelegate {

    private var mtkView: MTKView!
    private var renderer: Renderer!
    private var controls: TouchControlsView!
    private let crosshairLayer = CAShapeLayer()

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        mtkView = MTKView(frame: view.bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.preferredFramesPerSecond = 60
        view.addSubview(mtkView)

        guard let renderer = Renderer(mtkView: mtkView) else {
            fatalError("Renderer failed to initialize")
        }
        self.renderer = renderer
        mtkView.delegate = renderer

        controls = TouchControlsView(frame: view.bounds)
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.delegate = self
        view.addSubview(controls)

        crosshairLayer.strokeColor = UIColor.red.cgColor
        crosshairLayer.lineWidth = 2
        crosshairLayer.fillColor = UIColor.clear.cgColor
        view.layer.addSublayer(crosshairLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCrosshair()
    }

    private func updateCrosshair() {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let offset: CGFloat = 10
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x - offset, y: center.y))
        path.addLine(to: CGPoint(x: center.x + offset, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - offset))
        path.addLine(to: CGPoint(x: center.x, y: center.y + offset))
        crosshairLayer.path = path.cgPath
    }

    // MARK: - TouchControlsDelegate

    func touchControls(_ view: TouchControlsView, didUpdateMove displacement: SIMD2<Float>) {
        // Screen-up (negative dy) should move forward.
        renderer.moveInput = SIMD2<Float>(displacement.x, -displacement.y)
    }

    func touchControls(_ view: TouchControlsView, didUpdateLook displacement: SIMD2<Float>) {
        renderer.lookInput = displacement
    }

    func touchControlsFireTapped(_ view: TouchControlsView) {
        renderer.rayTest()
    }

    func touchControlsWireframeTapped(_ view: TouchControlsView) {
        renderer.toggleWireframe()
    }
}
