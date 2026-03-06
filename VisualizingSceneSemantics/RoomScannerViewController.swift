import UIKit
import RoomPlan
import ARKit

class RoomScannerViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate, ARSessionDelegate {
    
    var roomCaptureView: RoomCaptureView!
    var captureSessionConfig: RoomCaptureSession.Configuration!
    
    var onScanCompleted: ((UUID, ARWorldMap, CapturedRoom?) -> Void)?
    
    private let roomUUID = UUID()
    
    private var doneButton: UIButton?
    private var statusLabel: UILabel?
    private var activityIndicator: UIActivityIndicatorView?
    private let exitButton = UIButton(type: .system)
    
    private var isWorldMapReady: Bool = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        // Initialize RoomCaptureView
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView.captureSession.delegate = self
        roomCaptureView.delegate = self
        roomCaptureView.captureSession.arSession.delegate = self
        roomCaptureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(roomCaptureView)
        
        captureSessionConfig = RoomCaptureSession.Configuration()
        roomCaptureView.captureSession.run(configuration: captureSessionConfig)
        
        setupStatusLabel()
        setupActivityIndicator()
        setupDoneButton()
        setupExitButton()
    }
    
    private func setupStatusLabel() {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .white
        label.font = AppTheme.roundedFont(ofSize: 14, weight: .semibold)
        label.numberOfLines = 0
        label.text = "移动设备以开始建图"
        label.backgroundColor = AppTheme.overlayBackground
        label.layer.cornerRadius = 12
        label.layer.cornerCurve = .continuous
        label.layer.masksToBounds = true
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        
        statusLabel = label
    }
    
    private func setupActivityIndicator() {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        indicator.color = .white
        
        view.addSubview(indicator)
        
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        activityIndicator = indicator
    }
    
    private func setupDoneButton() {
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("完成扫描", for: .normal)
        AppTheme.stylePrimaryButton(doneButton)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isEnabled = false
        doneButton.alpha = 0.5
        
        view.addSubview(doneButton)
        
        NSLayoutConstraint.activate([
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 164),
            doneButton.heightAnchor.constraint(equalToConstant: 54)
        ])
        
        self.doneButton = doneButton
    }
    
    private func setupExitButton() {
        AppTheme.styleFloatingButton(exitButton)
        exitButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        exitButton.setTitle(nil, for: .normal)
        exitButton.tintColor = .white
        exitButton.contentEdgeInsets = .zero
        exitButton.imageView?.contentMode = .scaleAspectFit
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        
        view.addSubview(exitButton)
        
        NSLayoutConstraint.activate([
            exitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            exitButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            exitButton.widthAnchor.constraint(equalToConstant: 44),
            exitButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    @objc private func exitTapped() {
        roomCaptureView.captureSession.stop()
        dismiss(animated: true)
    }
    
    @objc private func doneTapped() {
        guard isWorldMapReady else {
            presentAlert(title: "还不能完成", message: "请继续移动设备，让系统完成建图后再点击“完成扫描”。")
            return
        }
        
        doneButton?.isEnabled = false
        doneButton?.alpha = 0.5
        activityIndicator?.startAnimating()
        
        roomCaptureView.captureSession.stop()
        
        roomCaptureView.captureSession.arSession.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.activityIndicator?.stopAnimating()
            }
            if let error = error {
                DispatchQueue.main.async {
                    self.presentAlert(title: "获取地图失败", message: error.localizedDescription)
                    self.updateDoneEnabled()
                }
                return
            }
            
            guard let map = worldMap else {
                DispatchQueue.main.async {
                    self.presentAlert(title: "地图尚未就绪", message: "请继续移动设备一会儿，再点击“完成扫描”。")
                    self.updateDoneEnabled()
                }
                return
            }
            
            self.onScanCompleted?(self.roomUUID, map, nil)
        }
    }
    
    private func updateDoneEnabled() {
        doneButton?.isEnabled = isWorldMapReady
        doneButton?.alpha = isWorldMapReady ? 1.0 : 0.5
    }
    
    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingOK: Bool
        switch frame.camera.trackingState {
        case .normal:
            trackingOK = true
        default:
            trackingOK = false
        }
        
        let mappingStatus = frame.worldMappingStatus
        let ready = trackingOK && (mappingStatus == .extending || mappingStatus == .mapped)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isWorldMapReady = ready
            self.updateDoneEnabled()
            
            if ready {
                self.statusLabel?.text = "可以点击“完成扫描”"
            } else {
                switch mappingStatus {
                case .notAvailable:
                    self.statusLabel?.text = "建图不可用，请确认设备支持并允许相机权限"
                case .limited:
                    self.statusLabel?.text = "建图中（精度较低），请继续移动设备"
                case .extending:
                    self.statusLabel?.text = "建图中，请继续移动设备"
                case .mapped:
                    self.statusLabel?.text = "可以点击“完成扫描”"
                @unknown default:
                    self.statusLabel?.text = "请继续移动设备"
                }
            }
        }
    }
    
    // MARK: - RoomCaptureViewDelegate
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }
    
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    }
}
