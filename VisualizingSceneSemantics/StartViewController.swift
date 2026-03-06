import UIKit
import ARKit
import RoomPlan

class StartViewController: UIViewController {
    
    private let cardContainer = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.pageBackground
        title = "房间扫描"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        
        setupUI()
    }
    
    private func setupUI() {
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        AppTheme.styleCard(cardContainer)
        view.addSubview(cardContainer)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "空间扫描与标注"
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.roundedFont(ofSize: 30, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "创建或加载历史房间，\n在真实空间编辑你的虚拟便签。"
        subtitleLabel.textColor = AppTheme.secondaryText
        subtitleLabel.font = AppTheme.roundedFont(ofSize: 15, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        
        let iconView = UIImageView(image: UIImage(systemName: "cube.transparent.fill"))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = AppTheme.accent
        iconView.contentMode = .scaleAspectFit
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 14
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(stackView)
        
        let preferredWidth = cardContainer.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.86)
        preferredWidth.priority = .defaultHigh
        
        NSLayoutConstraint.activate([
            cardContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            cardContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            preferredWidth,
            cardContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            
            stackView.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 28),
            stackView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -24),
            
            iconView.heightAnchor.constraint(equalToConstant: 46)
        ])
        
        let newRoomButton = createButton(title: "开始新扫描", action: #selector(newRoomTapped), isPrimary: true)
        let loadRoomButton = createButton(title: "加载历史房间", action: #selector(loadRoomTapped), isPrimary: false)
        
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(newRoomButton)
        stackView.addArrangedSubview(loadRoomButton)
    }
    
    private func createButton(title: String, action: Selector, isPrimary: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        if isPrimary {
            AppTheme.stylePrimaryButton(button)
        } else {
            AppTheme.styleSecondaryButton(button)
        }
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 54).isActive = true
        return button
    }
    
    @objc private func newRoomTapped() {
        let scannerVC = RoomScannerViewController()
        scannerVC.onScanCompleted = { [weak self] uuid, worldMap, room in
            // Dismiss the scanner
            self?.dismiss(animated: true) {
                // Prompt for Room Name
                self?.promptForRoomName { name in
                    // Save data with name
                    try? PersistenceManager.shared.saveRoom(uuid: uuid, worldMap: worldMap, room: room, name: name)
                    
                    // Transition to Note Mode
                    self?.navigateToNoteMode(worldMap: worldMap, roomUUID: uuid)
                }
            }
        }
        scannerVC.modalPresentationStyle = .fullScreen
        present(scannerVC, animated: true)
    }
    
    private func promptForRoomName(completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "Name Your Room", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Room"
            textField.text = "Room "
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            let rawName = alert.textFields?.first?.text ?? ""
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed.isEmpty ? "Room" : trimmed)
        }
        
        alert.addAction(saveAction)
        present(alert, animated: true) {
            guard let textField = alert.textFields?.first else { return }
            textField.becomeFirstResponder()
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
    }
    
    @objc private func loadRoomTapped() {
        let listVC = RoomListViewController()
        listVC.onRoomSelected = { [weak self] uuid in
            self?.loadRoom(uuid: uuid)
        }
        let nav = UINavigationController(rootViewController: listVC)
        present(nav, animated: true, completion: nil)
    }
    
    private func loadRoom(uuid: UUID) {
        do {
            let worldMap = try PersistenceManager.shared.loadWorldMap(uuid: uuid)
            navigateToNoteMode(worldMap: worldMap, roomUUID: uuid)
        } catch {
            print("Error loading room: \(error)")
        }
    }
    
    private func navigateToNoteMode(worldMap: ARWorldMap, roomUUID: UUID) {
        // Instantiate ViewController from Storyboard
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        guard let noteVC = storyboard.instantiateInitialViewController() as? ViewController else { return }
        
        // Pass the world map and ID
        noteVC.initialWorldMap = worldMap
        noteVC.currentRoomUUID = roomUUID
        
        // Push or Present
        // Note: ViewController (ARView) is heavy, usually better to present full screen or push
        // Since we are in Nav Controller
        
        // Ensure we are on main thread (though usually called from UI action)
        DispatchQueue.main.async {
            self.navigationController?.pushViewController(noteVC, animated: true)
        }
    }
}
