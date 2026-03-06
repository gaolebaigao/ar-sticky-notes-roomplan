import UIKit
import ARKit

class RoomListViewController: UITableViewController {
    
    var onRoomSelected: ((UUID) -> Void)?
    private var rooms: [(UUID, String)] = []
    
    init() {
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "选择房间"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "RoomCell")
        tableView.rowHeight = 58
        tableView.backgroundColor = .systemGroupedBackground
        tableView.sectionHeaderTopPadding = 8
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        
        refreshRooms()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRooms()
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true, completion: nil)
    }
    
    private func refreshRooms() {
        rooms = PersistenceManager.shared.listSavedRooms().sorted(by: { $0.1 < $1.1 })
        tableView.reloadData()
        updateBackgroundView()
    }
    
    private func updateBackgroundView() {
        guard rooms.isEmpty else {
            tableView.backgroundView = nil
            tableView.backgroundColor = .systemGroupedBackground
            return
        }
        
        let label = UILabel()
        label.text = "暂无已保存房间\n请先创建新扫描。"
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        
        let container = UIView()
        container.backgroundColor = .systemGroupedBackground
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
        ])
        
        tableView.backgroundView = container
    }
    
    // MARK: - Table view data source
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rooms.count
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !rooms.isEmpty else { return nil }
        return "已保存房间 \(rooms.count)"
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RoomCell", for: indexPath)
        let room = rooms[indexPath.row]
        let safeName = room.1.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var content = cell.defaultContentConfiguration()
        content.text = safeName.isEmpty ? "未命名房间" : safeName
        content.textProperties.color = .label
        content.textProperties.font = AppTheme.roundedFont(ofSize: 17, weight: .semibold)
        content.image = UIImage(systemName: "square.stack.3d.up.fill")
        content.imageProperties.tintColor = .systemBlue
        content.imageToTextPadding = 12
        cell.contentConfiguration = content
        
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let room = rooms[indexPath.row]
        onRoomSelected?(room.0)
        dismiss(animated: true, completion: nil)
    }
    
    // MARK: - Context Menu (Long Press)
    
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let renameAction = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
                self?.promptRename(at: indexPath)
            }
            
            let deleteAction = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.confirmDelete(at: indexPath)
            }
            
            return UIMenu(title: "", children: [renameAction, deleteAction])
        }
    }
    
    private func promptRename(at indexPath: IndexPath) {
        let room = rooms[indexPath.row]
        let alert = UIAlertController(title: "Rename Room", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = room.1
            textField.placeholder = "New Room Name"
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak self] _ in
            guard let newName = alert.textFields?.first?.text, !newName.isEmpty else { return }
            do {
                try PersistenceManager.shared.renameRoom(uuid: room.0, newName: newName)
                self?.refreshRooms()
            } catch {
                print("Error renaming room: \(error)")
            }
        }))
        
        present(alert, animated: true, completion: nil)
    }
    
    private func confirmDelete(at indexPath: IndexPath) {
        let room = rooms[indexPath.row]
        let alert = UIAlertController(
            title: "Delete Room",
            message: "Are you sure you want to delete \"\(room.1)\"? This cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
            do {
                try PersistenceManager.shared.deleteRoom(uuid: room.0)
                self?.refreshRooms()
            } catch {
                print("Error deleting room: \(error)")
            }
        }))
        
        present(alert, animated: true, completion: nil)
    }
}
