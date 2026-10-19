import AVFoundation
import SwiftUI

/// 扫描 Mac 端展示的配对二维码。模拟器没有相机，会显示不可用提示。
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
    }
}

private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.agentgrid.mobile.scanner")
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let box = SessionBox()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let messageLabel = UILabel()
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        Task { await prepare() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let box = box
        box.queue.async { box.session.stopRunning() }
    }

    private func prepare() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return show("需要相机权限才能扫码，也可以改用粘贴配对文本。")
            }
        default:
            return show("相机权限已关闭，请在系统设置中允许，或改用粘贴配对文本。")
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              box.session.canAddInput(input) else {
            return show("这台设备没有可用的相机，请改用粘贴配对文本。")
        }
        let output = AVCaptureMetadataOutput()
        box.session.addInput(input)
        guard box.session.canAddOutput(output) else {
            return show("无法启动扫码，请改用粘贴配对文本。")
        }
        box.session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: box.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        messageLabel.isHidden = true
        let box = box
        box.queue.async { box.session.startRunning() }
    }

    private func show(_ message: String) {
        messageLabel.text = message
        messageLabel.isHidden = false
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        guard let value else { return }
        MainActor.assumeIsolated {
            guard !delivered else { return }
            delivered = true
            onCode?(value)
        }
    }
}
