/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import RealityKit
import ARKit
import Combine

class ViewController: UIViewController, ARSessionDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    @IBOutlet var arView: ARView!
    @IBOutlet weak var hideMeshButton: UIButton!
    @IBOutlet weak var resetButton: UIButton!
    
    let coachingOverlay = ARCoachingOverlayView()
    
    // Cache for 3D text geometries representing the classification values.
    var modelsForClassification: [ARMeshClassification: ModelEntity] = [:]
    
    // Track the currently selected note for editing
    var selectedNoteEntity: ModelEntity?
    
    // Subscription for texture loading
    var textureLoadSubscription: AnyCancellable?
    
    // Loaded World Map (if any)
    var initialWorldMap: ARWorldMap?
    
    // Current Room UUID
    var currentRoomUUID: UUID?
    
    private var pendingRestoreRoomUUID: UUID?
    private var didRestoreNotes = false
    private var shouldWaitForRelocalization = false
    private var hasConfirmedRelocalization = false
    private var hasSeenRelocalizingState = false
    private var relocalizationStableFrameCount = 0
    private var lastRelocalizationStatus: String?
    private let relocalizationBanner = UIView()
    private let relocalizationBannerLabel = UILabel()
    private var lastRelocalizationBlockedAlertTime: Date?
    private let exitButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        
        arView.session.delegate = self
        
        setupCoachingOverlay()

        arView.environment.sceneUnderstanding.options = []
        
        // Turn on occlusion from the scene reconstruction's mesh.
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        
        // Turn on physics for the scene reconstruction's mesh.
        arView.environment.sceneUnderstanding.options.insert(.physics)

        // Display a debug visualization of the mesh.
        // arView.debugOptions.insert(.showSceneUnderstanding)
        
        // For performance, disable render options that are not required for this app.
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField, .disableMotionBlur]
        
        // Manually configure what kind of AR session to run since
        // ARView on its own does not turn on mesh classification.
        arView.automaticallyConfigureSession = false
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .automatic
        
        // Load initial world map if available
        if let worldMap = initialWorldMap {
            configuration.initialWorldMap = worldMap
            shouldWaitForRelocalization = true
            hasConfirmedRelocalization = false
            print("Configuring session with loaded WorldMap")
        } else {
            hasConfirmedRelocalization = true
        }

        let runOptions: ARSession.RunOptions = [.resetTracking, .removeExistingAnchors]
        arView.session.run(configuration, options: runOptions)
        
        setupRelocalizationBanner()
        updateRelocalizationBannerText()
        setupControlButtons()
        setupExitButton()
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapRecognizer)
        
        // Restore notes if available
        if let roomUUID = currentRoomUUID {
            pendingRestoreRoomUUID = roomUUID
            if !shouldWaitForRelocalization {
                didRestoreNotes = true
                restoreNotes(for: roomUUID)
            }
        }
        
        // Listen for background notification to save data
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    @objc func applicationWillResignActive() {
        saveNotes()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    
    func restoreNotes(for uuid: UUID) {
        guard let notes = try? PersistenceManager.shared.loadNotes(uuid: uuid) else { return }
        print("Restoring \(notes.count) notes")
        
        for note in notes {
            let noteRootWorldTransform = note.noteRootTransform ?? note.transform
            let anchor = AnchorEntity(world: noteRootWorldTransform)
            addRestoredNoteContent(to: anchor, note: note, roomUUID: uuid)
            arView.scene.addAnchor(anchor)
        }
    }
    
    private func addRestoredNoteContent(to parent: Entity, note: NoteData, roomUUID: UUID) {
        let pinEntity = createPin()
        parent.addChild(pinEntity)
        
        let noteSize: Float = 0.1
        let normalOffset: Float = 0.0015
        let droopAngle: Float = -0.45
        
        let noteHinge = Entity()
        noteHinge.position = SIMD3<Float>(0, normalOffset, 0)
        noteHinge.orientation = simd_quatf(angle: droopAngle, axis: [1, 0, 0])
        
        let mesh = MeshResource.generatePlane(width: noteSize, depth: noteSize, cornerRadius: 0.005)
        let material = SimpleMaterial(color: .yellow, isMetallic: false)
        let noteEntity = ModelEntity(mesh: mesh, materials: [material])
        noteEntity.name = "StickyNote"
        noteEntity.generateCollisionShapes(recursive: true)
        noteEntity.position = SIMD3<Float>(0, 0, noteSize / 2)

        let content = NoteContentComponent(text: note.text, imageFilename: note.imageFilename)
        setNoteContent(content, for: noteEntity)

        if let imageFilename = note.imageFilename,
           let image = try? PersistenceManager.shared.loadNoteImage(uuid: roomUUID, filename: imageFilename) {
            updateNoteTexture(with: image, for: noteEntity)
        } else if let text = note.text {
            let textImage = imageFromText(text, on: .yellow)
            updateNoteTexture(with: textImage, for: noteEntity)
        }
        
        noteHinge.addChild(noteEntity)
        parent.addChild(noteHinge)
    }
    
    func saveNotes() {
        guard let uuid = currentRoomUUID else { return }
        
        if shouldWaitForRelocalization && !hasConfirmedRelocalization {
            print("Skipping save because relocalization is not confirmed yet")
            showSaveBlockedHint()
            return
        }
        
        let notes = collectNotesForPersistence()
        
        print("Saving \(notes.count) notes for room \(uuid)")
        
        // Persist
        // We capture the current WorldMap to ensure the notes are saved relative to the latest environment data.
        // This is crucial for accurate relocalization when reloading.
        
        // Use a DispatchGroup to wait for the map capture if we are in a critical state (like resigning active)
        let group = DispatchGroup()
        group.enter()
        
        arView.session.getCurrentWorldMap { worldMap, error in
            if let map = worldMap {
                do {
                    try PersistenceManager.shared.saveNotesAndMap(uuid: uuid, notes: notes, worldMap: map)
                    print("Successfully saved WorldMap and Notes")
                } catch {
                    print("Error saving WorldMap: \(error)")
                }
            } else {
                print("WorldMap unavailable: \(String(describing: error))")
                // Fallback: save just the notes if map capture fails
                try? PersistenceManager.shared.saveNotes(uuid: uuid, notes: notes)
            }
            group.leave()
        }
        
        // Wait for the async operation to complete (max 2 seconds)
        // This ensures that when the app is suspended/terminated, the data is written.
        let result = group.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            print("Warning: Timed out waiting for WorldMap capture")
            // Try to save notes only if timeout occurred (better than nothing)
            try? PersistenceManager.shared.saveNotes(uuid: uuid, notes: notes)
        }
    }
    
    func findNoteEntity(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.name.starts(with: "StickyNote") {
            return model
        }
        
        for child in entity.children {
            if let found = findNoteEntity(in: child) {
                return found
            }
        }
        return nil
    }
    
    func parseTextFromNoteName(_ name: String) -> String? {
        // Format: "StickyNote:TEXT"
        let components = name.split(separator: ":", maxSplits: 1)
        if components.count > 1 {
            return String(components[1])
        }
        return nil
    }

    private func noteContent(for entity: Entity) -> NoteContentComponent {
        if let content = entity.components[NoteContentComponent.self] {
            return content
        }
        return NoteContentComponent(text: parseTextFromNoteName(entity.name), imageFilename: nil)
    }

    private func setNoteContent(_ content: NoteContentComponent, for entity: ModelEntity) {
        entity.name = "StickyNote"
        entity.components.set(content)
    }
    
    private func collectNotesForPersistence() -> [NoteData] {
        var notes: [NoteData] = []
        
        for anchor in arView.scene.anchors {
            guard let noteEntity = findNoteEntity(in: anchor) else { continue }
            let content = noteContent(for: noteEntity)
            
            let noteRootTransform: simd_float4x4?
            if let noteHinge = noteEntity.parent {
                if let noteRoot = noteHinge.parent {
                    noteRootTransform = noteRoot.transformMatrix(relativeTo: nil)
                } else {
                    noteRootTransform = noteHinge.transformMatrix(relativeTo: nil)
                }
            } else {
                noteRootTransform = nil
            }
            
            let noteData = NoteData(
                transform: anchor.transformMatrix(relativeTo: nil),
                text: content.text,
                imageFilename: content.imageFilename,
                noteRootTransform: noteRootTransform
            )
            notes.append(noteData)
        }
        
        return notes
    }
    
    // Call this when app is going to background or view disappearing
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNotes()
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Prevent the screen from being dimmed to avoid interrupting the AR experience.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard shouldWaitForRelocalization, !didRestoreNotes, let uuid = pendingRestoreRoomUUID else { return }
        
        DispatchQueue.main.async {
            self.updateRelocalizationBannerText(for: frame.camera.trackingState)
        }

        let status = "\(trackingStateDescription(frame.camera.trackingState))|\(frame.worldMappingStatus.rawValue)"
        if status != lastRelocalizationStatus {
            lastRelocalizationStatus = status
            print("Relocalization status: \(status)")
        }
        
        switch frame.camera.trackingState {
        case .limited(.relocalizing):
            hasSeenRelocalizingState = true
            relocalizationStableFrameCount = 0
            return
        case .normal:
            let mappingReady = frame.worldMappingStatus == .extending || frame.worldMappingStatus == .mapped
            guard mappingReady else {
                relocalizationStableFrameCount = 0
                return
            }
            relocalizationStableFrameCount += 1
            let requiredFrames = hasSeenRelocalizingState ? 30 : 90
            guard relocalizationStableFrameCount >= requiredFrames else { return }
        default:
            relocalizationStableFrameCount = 0
            return
        }
        
        hasConfirmedRelocalization = true
        didRestoreNotes = true
        pendingRestoreRoomUUID = nil
        print("Relocalization confirmed, restoring notes")
        
        DispatchQueue.main.async {
            self.updateRelocalizationBannerText(for: frame.camera.trackingState)
        }
        
        DispatchQueue.main.async {
            self.restoreNotes(for: uuid)
        }
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    func saveNotesOnly() {
        guard let uuid = currentRoomUUID else { return }
        
        let notes = collectNotesForPersistence()
        
        // Lightweight save of just the notes
        try? PersistenceManager.shared.saveNotes(uuid: uuid, notes: notes)
    }
    
    /// Places a spatial note at the touch-location's real-world intersection with a mesh.
    @objc
    func handleTap(_ sender: UITapGestureRecognizer) {
        if shouldWaitForRelocalization && !didRestoreNotes {
            print("Ignoring tap while waiting for relocalization")
            presentRelocalizationBlockedAlert(action: "编辑或添加标签")
            return
        }
        
        let tapLocation = sender.location(in: arView)
        
        if let hitEntity = arView.entity(at: tapLocation) as? ModelEntity, hitEntity.name.starts(with: "StickyNote") {
            showEditMenu(for: hitEntity)
            return
        }

        if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .any).first {
            let hitPosition = result.worldTransform.position
            let cameraMatrix = arView.cameraTransform.matrix
            let cameraPosition = SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
            let toCamera = normalize(cameraPosition - hitPosition)
            
            var surfaceNormalWorld = SIMD3<Float>(result.worldTransform.columns.1.x, result.worldTransform.columns.1.y, result.worldTransform.columns.1.z)
            if dot(surfaceNormalWorld, toCamera) < 0 {
                surfaceNormalWorld = -surfaceNormalWorld
            }
            
            let gravityWorld = SIMD3<Float>(0, -1, 0)
            var downWorld = gravityWorld - surfaceNormalWorld * dot(gravityWorld, surfaceNormalWorld)
            
            if length(downWorld) < 0.001 {
                let cameraForward4 = -cameraMatrix.columns.2
                let cameraForward = SIMD3<Float>(cameraForward4.x, cameraForward4.y, cameraForward4.z)
                downWorld = cameraForward - surfaceNormalWorld * dot(cameraForward, surfaceNormalWorld)
                if length(downWorld) < 0.001 {
                    let fallback = SIMD3<Float>(0, 0, 1)
                    downWorld = fallback - surfaceNormalWorld * dot(fallback, surfaceNormalWorld)
                }
            }
            
            downWorld = normalize(downWorld)
            if dot(downWorld, gravityWorld) < 0 {
                downWorld = -downWorld
            }
            var rightWorld = cross(surfaceNormalWorld, downWorld)
            if length(rightWorld) < 0.001 {
                rightWorld = cross(surfaceNormalWorld, SIMD3<Float>(1, 0, 0))
            }
            rightWorld = normalize(rightWorld)
            downWorld = normalize(cross(rightWorld, surfaceNormalWorld))
            
            let anchor = AnchorEntity(world: hitPosition)
            
            let noteRoot = Entity()
            noteRoot.orientation = simd_quatf(simd_float3x3(columns: (rightWorld, surfaceNormalWorld, downWorld)))
            
            let rayDirectionWorld = normalize(cameraPosition - hitPosition)
            let pinEntity = createRayPin(directionWorld: rayDirectionWorld, parentOrientation: noteRoot.orientation)
            noteRoot.addChild(pinEntity)
            
            let noteSize: Float = 0.1
            let normalOffset: Float = 0.0015
            let droopAngle: Float = -0.45
            
            let noteHinge = Entity()
            noteHinge.position = SIMD3<Float>(0, normalOffset, 0)
            noteHinge.orientation = simd_quatf(angle: droopAngle, axis: [1, 0, 0])
            noteRoot.addChild(noteHinge)
            
            let mesh = MeshResource.generatePlane(width: noteSize, depth: noteSize, cornerRadius: 0.005)
            let material = SimpleMaterial(color: .yellow, isMetallic: false)
            let noteEntity = ModelEntity(mesh: mesh, materials: [material])
            noteEntity.name = "StickyNote"
            noteEntity.generateCollisionShapes(recursive: true)
            noteEntity.position = SIMD3<Float>(0, 0, noteSize / 2)
            setNoteContent(NoteContentComponent(), for: noteEntity)
            
            noteHinge.addChild(noteEntity)
            anchor.addChild(noteRoot)
            arView.scene.addAnchor(anchor)
            
            // Save notes immediately to prevent data loss if app crashes/exits before full save
            saveNotesOnly()
        }
    }
    
    func createPin() -> ModelEntity {
        let headMesh = MeshResource.generateSphere(radius: 0.004)
        let headMaterial = SimpleMaterial(color: .red, isMetallic: false)
        let headEntity = ModelEntity(mesh: headMesh, materials: [headMaterial])
        headEntity.position.y = 0.015
        
        let shaftMesh = MeshResource.generateBox(size: [0.001, 0.015, 0.001], cornerRadius: 0.0005)
        let shaftMaterial = SimpleMaterial(color: .gray, isMetallic: true)
        let shaftEntity = ModelEntity(mesh: shaftMesh, materials: [shaftMaterial])
        shaftEntity.position.y = 0.0075
        
        let pinEntity = ModelEntity()
        pinEntity.addChild(shaftEntity)
        pinEntity.addChild(headEntity)
        
        return pinEntity
    }
    
    func createRayPin(directionWorld: SIMD3<Float>, parentOrientation: simd_quatf) -> ModelEntity {
        let pinLength: Float = 0.06 // Total length of pin
        let headRadius: Float = 0.004
        
        // Pin Head (Red Sphere)
        let headMesh = MeshResource.generateSphere(radius: headRadius)
        let headMaterial = SimpleMaterial(color: .red, isMetallic: false)
        let headEntity = ModelEntity(mesh: headMesh, materials: [headMaterial])
        // Head is at the end of the shaft
        headEntity.position.y = pinLength
        
        // Pin Shaft (Gray Cylinder)
        let shaftRadius: Float = 0.001
        let shaftMesh = MeshResource.generateBox(size: [shaftRadius, pinLength, shaftRadius], cornerRadius: shaftRadius/2)
        let shaftMaterial = SimpleMaterial(color: .gray, isMetallic: true)
        let shaftEntity = ModelEntity(mesh: shaftMesh, materials: [shaftMaterial])
        // Shaft center is at y = pinLength/2
        shaftEntity.position.y = pinLength / 2
        
        let pinEntity = ModelEntity()
        pinEntity.addChild(shaftEntity)
        pinEntity.addChild(headEntity)
        
        // Rotate pin to match ray direction
        // Pin default orientation is +Y (Up)
        // We want +Y to align with directionLocal
        let directionLocal = normalize(parentOrientation.inverse.act(directionWorld))
        pinEntity.orientation = simd_quatf(from: [0, 1, 0], to: directionLocal)
        
        return pinEntity
    }
    
    func showEditMenu(for entity: ModelEntity) {
        self.selectedNoteEntity = entity
        let alert = UIAlertController(title: "Edit Note", message: "Choose an action", preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Add Text", style: .default, handler: { _ in
            self.promptForText()
        }))
        
        alert.addAction(UIAlertAction(title: "Add Image", style: .default, handler: { _ in
            self.promptForImage()
        }))
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        // For iPad support
        if let popover = alert.popoverPresentationController {
            popover.sourceView = arView
            popover.sourceRect = CGRect(x: arView.bounds.midX, y: arView.bounds.midY, width: 0, height: 0)
        }
        
        present(alert, animated: true, completion: nil)
    }
    
    func promptForText() {
        let alert = UIAlertController(title: "Enter Text", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Note text..."
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
            guard let text = alert.textFields?.first?.text, !text.isEmpty else { return }
            self?.updateNoteWithText(text)
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
    func promptForImage() {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true, completion: nil)
    }
    
    func updateNoteWithText(_ text: String) {
        guard let entity = selectedNoteEntity else { return }

        var content = noteContent(for: entity)
        if let imageFilename = content.imageFilename, let uuid = currentRoomUUID {
            try? PersistenceManager.shared.deleteNoteImage(uuid: uuid, filename: imageFilename)
        }
        content.text = text
        content.imageFilename = nil
        setNoteContent(content, for: entity)

        // Generate an image with the text
        let image = imageFromText(text, on: .yellow)
        updateNoteTexture(with: image, for: entity)
        saveNotesOnly()
    }
    
    func imageFromText(_ text: String, on backgroundColor: UIColor) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Draw background
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Draw text
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
            
            let attributedString = NSAttributedString(string: text, attributes: attributes)
            
            // Center the text
            let textRect = attributedString.boundingRect(with: CGSize(width: size.width - 40, height: size.height - 40),
                                                         options: .usesLineFragmentOrigin,
                                                         context: nil)
            
            let x = (size.width - textRect.width) / 2
            let y = (size.height - textRect.height) / 2
            
            attributedString.draw(in: CGRect(x: x, y: y, width: textRect.width, height: textRect.height))
        }
    }
    
    func updateNoteTexture(with image: UIImage, for entity: ModelEntity) {
        guard let cgImage = image.cgImage else { return }
        
        if #available(iOS 15.0, *) {
            do {
                let texture = try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
                var material = SimpleMaterial()
                material.color = .init(texture: .init(texture))
                material.metallic = .float(0.0)
                material.roughness = .float(1.0)
                entity.model?.materials = [material]
            } catch {
                print("Error creating texture: \(error)")
            }
        } else {
            // iOS 13/14 Fallback: Save to file and load asynchronously
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("temp_note_texture.png")
                try image.pngData()?.write(to: url)
                
                textureLoadSubscription = TextureResource.loadAsync(contentsOf: url)
                    .sink(receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            print("Error loading texture: \(error)")
                        }
                    }, receiveValue: { [weak entity] texture in
                        var material = SimpleMaterial()
                        material.baseColor = MaterialColorParameter.texture(texture)
                        material.metallic = .float(0.0)
                        material.roughness = .float(1.0)
                        entity?.model?.materials = [material]
                    })
            } catch {
                 print("Error saving temp image: \(error)")
            }
        }
    }
    
    // MARK: - UIImagePickerControllerDelegate
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true, completion: nil)
        
        if let image = info[.originalImage] as? UIImage {
            guard let entity = selectedNoteEntity else { return }
            var content = noteContent(for: entity)
            if let uuid = currentRoomUUID {
                do {
                    let filename = try PersistenceManager.shared.saveNoteImage(
                        uuid: uuid,
                        image: image,
                        preferredFilename: content.imageFilename
                    )
                    content.imageFilename = filename
                    setNoteContent(content, for: entity)
                } catch {
                    print("Error saving note image: \(error)")
                }
            }

            // For images, we might want to keep aspect ratio or just fill the square note.
            // For simplicity, we just apply it to the square note.
            updateNoteTexture(with: image, for: entity)
            saveNotesOnly()
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
    
    @IBAction func resetButtonPressed(_ sender: Any) {
        if let configuration = arView.session.configuration {
            arView.session.run(configuration, options: .resetSceneReconstruction)
        }
    }
    
    @IBAction func toggleMeshButtonPressed(_ button: UIButton) {
        let isShowingMesh = arView.debugOptions.contains(.showSceneUnderstanding)
        if isShowingMesh {
            arView.debugOptions.remove(.showSceneUnderstanding)
            button.setTitle("显示网格", for: [])
        } else {
            arView.debugOptions.insert(.showSceneUnderstanding)
            button.setTitle("隐藏网格", for: [])
        }
    }
    
    func nearbyFaceWithClassification(to location: SIMD3<Float>, completionBlock: @escaping (SIMD3<Float>?, ARMeshClassification) -> Void) {
        guard let frame = arView.session.currentFrame else {
            completionBlock(nil, .none)
            return
        }
    
        var meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        // Sort the mesh anchors by distance to the given location and filter out
        // any anchors that are too far away (4 meters is a safe upper limit).
        let cutoffDistance: Float = 4.0
        meshAnchors.removeAll { distance($0.transform.position, location) > cutoffDistance }
        meshAnchors.sort { distance($0.transform.position, location) < distance($1.transform.position, location) }

        // Perform the search asynchronously in order not to stall rendering.
        DispatchQueue.global().async {
            for anchor in meshAnchors {
                for index in 0..<anchor.geometry.faces.count {
                    // Get the center of the face so that we can compare it to the given location.
                    let geometricCenterOfFace = anchor.geometry.centerOf(faceWithIndex: index)
                    
                    // Convert the face's center to world coordinates.
                    var centerLocalTransform = matrix_identity_float4x4
                    centerLocalTransform.columns.3 = SIMD4<Float>(geometricCenterOfFace.0, geometricCenterOfFace.1, geometricCenterOfFace.2, 1)
                    let centerWorldPosition = (anchor.transform * centerLocalTransform).position
                     
                    // We're interested in a classification that is sufficiently close to the given location––within 5 cm.
                    let distanceToFace = distance(centerWorldPosition, location)
                    if distanceToFace <= 0.05 {
                        // Get the semantic classification of the face and finish the search.
                        let classification: ARMeshClassification = anchor.geometry.classificationOf(faceWithIndex: index)
                        completionBlock(centerWorldPosition, classification)
                        return
                    }
                }
            }
            
            // Let the completion block know that no result was found.
            completionBlock(nil, .none)
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            // Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                self.resetButtonPressed(self)
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
        
    func model(for classification: ARMeshClassification) -> ModelEntity {
        // Return cached model if available
        if let model = modelsForClassification[classification] {
            model.transform = .identity
            return model.clone(recursive: true)
        }
        
        // Generate 3D text for the classification
        let lineHeight: CGFloat = 0.05
        let font = MeshResource.Font.systemFont(ofSize: lineHeight)
        let textMesh = MeshResource.generateText(classification.description, extrusionDepth: Float(lineHeight * 0.1), font: font)
        let textMaterial = SimpleMaterial(color: classification.color, isMetallic: true)
        let model = ModelEntity(mesh: textMesh, materials: [textMaterial])
        // Move text geometry to the left so that its local origin is in the center
        model.position.x -= model.visualBounds(relativeTo: nil).extents.x / 2
        // Add model to cache
        modelsForClassification[classification] = model
        return model
    }
    
    func sphere(radius: Float, color: UIColor) -> ModelEntity {
        let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [SimpleMaterial(color: color, isMetallic: false)])
        // Move sphere up by half its diameter so that it does not intersect with the mesh
        sphere.position.y = radius
        return sphere
    }
    
    private func trackingStateDescription(_ trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .notAvailable:
            return "notAvailable"
        case .normal:
            return "normal"
        case .limited(let reason):
            return "limited.\(trackingReasonDescription(reason))"
        }
    }
    
    private func trackingReasonDescription(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            return "initializing"
        case .excessiveMotion:
            return "excessiveMotion"
        case .insufficientFeatures:
            return "insufficientFeatures"
        case .relocalizing:
            return "relocalizing"
        @unknown default:
            return "unknown"
        }
    }
    
    private func setupRelocalizationBanner() {
        relocalizationBanner.translatesAutoresizingMaskIntoConstraints = false
        relocalizationBanner.backgroundColor = AppTheme.overlayBackground
        relocalizationBanner.layer.cornerRadius = 12
        relocalizationBanner.layer.cornerCurve = .continuous
        relocalizationBanner.layer.borderWidth = 1
        relocalizationBanner.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        relocalizationBanner.layer.masksToBounds = true
        relocalizationBanner.isHidden = true
        
        relocalizationBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        relocalizationBannerLabel.textColor = .white
        relocalizationBannerLabel.font = AppTheme.roundedFont(ofSize: 14, weight: .semibold)
        relocalizationBannerLabel.numberOfLines = 0
        relocalizationBannerLabel.textAlignment = .center
        
        relocalizationBanner.addSubview(relocalizationBannerLabel)
        view.addSubview(relocalizationBanner)
        
        NSLayoutConstraint.activate([
            relocalizationBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            relocalizationBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            relocalizationBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            relocalizationBannerLabel.topAnchor.constraint(equalTo: relocalizationBanner.topAnchor, constant: 10),
            relocalizationBannerLabel.leadingAnchor.constraint(equalTo: relocalizationBanner.leadingAnchor, constant: 12),
            relocalizationBannerLabel.trailingAnchor.constraint(equalTo: relocalizationBanner.trailingAnchor, constant: -12),
            relocalizationBannerLabel.bottomAnchor.constraint(equalTo: relocalizationBanner.bottomAnchor, constant: -10)
        ])
    }
    
    private func setupControlButtons() {
        hideMeshButton.setTitle("隐藏网格", for: .normal)
        resetButton.setTitle("重置", for: .normal)
        AppTheme.styleFloatingButton(hideMeshButton)
        AppTheme.styleFloatingButton(resetButton)
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
        if let nav = navigationController, nav.viewControllers.first != self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
    
    private func updateRelocalizationBannerText(for trackingState: ARCamera.TrackingState? = nil) {
        let isBlocked = shouldWaitForRelocalization && !hasConfirmedRelocalization
        relocalizationBanner.isHidden = !isBlocked
        guard isBlocked else { return }
        
        let guidance: String
        if let trackingState = trackingState {
            switch trackingState {
            case .limited(.relocalizing):
                guidance = "正在重定位，请对准原场景并缓慢移动。"
            case .limited(.insufficientFeatures):
                guidance = "特征不足，请对准有纹理区域并缓慢移动。"
            case .limited(.excessiveMotion):
                guidance = "移动过快，请放慢并对准原场景。"
            case .limited(.initializing):
                guidance = "正在初始化跟踪，请稍候。"
            default:
                guidance = "请返回原扫描区域完成重定位。"
            }
        } else {
            guidance = "请返回原扫描区域完成重定位。"
        }
        
        relocalizationBannerLabel.text = "重定位未完成：禁止编辑和保存标签。\n\(guidance)"
    }
    
    private func showSaveBlockedHint() {
        DispatchQueue.main.async {
            guard self.shouldWaitForRelocalization && !self.hasConfirmedRelocalization else { return }
            self.relocalizationBanner.isHidden = false
            self.relocalizationBannerLabel.text = "重定位未完成：已阻止保存。\n请返回原扫描区域完成重定位。"
        }
    }
    
    private func presentRelocalizationBlockedAlert(action: String) {
        guard shouldWaitForRelocalization && !hasConfirmedRelocalization else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard viewIfLoaded?.window != nil else { return }
        guard presentedViewController == nil else { return }
        
        let now = Date()
        if let last = lastRelocalizationBlockedAlertTime, now.timeIntervalSince(last) < 1.5 {
            return
        }
        lastRelocalizationBlockedAlertTime = now
        
        let alert = UIAlertController(
            title: "重定位未完成",
            message: "请先回到原场景并完成重定位，完成前无法\(action)。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
