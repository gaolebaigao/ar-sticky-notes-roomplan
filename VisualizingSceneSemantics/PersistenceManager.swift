import Foundation
import ARKit
import RoomPlan
import UIKit

struct RoomMetadata: Codable {
    let name: String
    let date: Date
}

struct PersistenceManager {
    static let shared = PersistenceManager()
    
    private let fileManager = FileManager.default
    
    private var roomsDirectory: URL {
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        let docDir = paths[0]
        let roomsDir = docDir.appendingPathComponent("Rooms", isDirectory: true)
        if !fileManager.fileExists(atPath: roomsDir.path) {
            try? fileManager.createDirectory(at: roomsDir, withIntermediateDirectories: true)
        }
        return roomsDir
    }

    private func roomDirectory(uuid: UUID, createIfNeeded: Bool = false) throws -> URL {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString, isDirectory: true)
        if createIfNeeded, !fileManager.fileExists(atPath: roomDir.path) {
            try fileManager.createDirectory(at: roomDir, withIntermediateDirectories: true)
        }
        return roomDir
    }

    private func noteImagesDirectory(uuid: UUID, createIfNeeded: Bool = false) throws -> URL {
        let roomDir = try roomDirectory(uuid: uuid, createIfNeeded: createIfNeeded)
        let imagesDir = roomDir.appendingPathComponent("Images", isDirectory: true)
        if createIfNeeded, !fileManager.fileExists(atPath: imagesDir.path) {
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
        return imagesDir
    }
    
    func saveRoom(uuid: UUID, worldMap: ARWorldMap, room: CapturedRoom?, notes: [NoteData]? = nil, name: String? = nil) throws {
        let roomDir = try roomDirectory(uuid: uuid, createIfNeeded: true)
        
        // Save WorldMap
        let mapURL = roomDir.appendingPathComponent("worldMap.map")
        let mapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try mapData.write(to: mapURL)
        
        // Save RoomPlan data
        if let room = room {
            let roomURL = roomDir.appendingPathComponent("room.json")
            try room.export(to: roomURL)
        }
        
        // Save Notes
        if let notes = notes {
            let notesURL = roomDir.appendingPathComponent("notes.json")
            let notesData = try JSONEncoder().encode(notes)
            try notesData.write(to: notesURL)
        }
        
        // Save Metadata (Name)
        // If name is provided, save/update it. If not, preserve existing or default.
        var metadata = getRoomMetadata(uuid: uuid) ?? RoomMetadata(name: "Room \(uuid.uuidString.prefix(4))", date: Date())
        if let newName = name {
            metadata = RoomMetadata(name: newName, date: metadata.date)
        }
        
        let metaURL = roomDir.appendingPathComponent("metadata.json")
        let metaData = try JSONEncoder().encode(metadata)
        try metaData.write(to: metaURL)
        
        print("Saved room data to \(roomDir.path)")
    }
    
    func getRoomMetadata(uuid: UUID) -> RoomMetadata? {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        let metaURL = roomDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(RoomMetadata.self, from: data)
    }
    
    func renameRoom(uuid: UUID, newName: String) throws {
        var metadata = getRoomMetadata(uuid: uuid) ?? RoomMetadata(name: newName, date: Date())
        metadata = RoomMetadata(name: newName, date: metadata.date)
        
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        let metaURL = roomDir.appendingPathComponent("metadata.json")
        let metaData = try JSONEncoder().encode(metadata)
        try metaData.write(to: metaURL)
    }
    
    func deleteRoom(uuid: UUID) throws {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        if fileManager.fileExists(atPath: roomDir.path) {
            try fileManager.removeItem(at: roomDir)
        }
    }
    
    func loadNotes(uuid: UUID) throws -> [NoteData] {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        let notesURL = roomDir.appendingPathComponent("notes.json")
        
        if !fileManager.fileExists(atPath: notesURL.path) {
            return []
        }
        
        let notesData = try Data(contentsOf: notesURL)
        return try JSONDecoder().decode([NoteData].self, from: notesData)
    }
    
    func saveNotes(uuid: UUID, notes: [NoteData]) throws {
        let roomDir = try roomDirectory(uuid: uuid, createIfNeeded: true)
        
        let notesURL = roomDir.appendingPathComponent("notes.json")
        let notesData = try JSONEncoder().encode(notes)
        try notesData.write(to: notesURL)
        print("Saved \(notes.count) notes to \(notesURL.path)")
    }
    
    func saveNotesAndMap(uuid: UUID, notes: [NoteData], worldMap: ARWorldMap) throws {
        let roomDir = try roomDirectory(uuid: uuid, createIfNeeded: true)
        
        // Save Notes
        let notesURL = roomDir.appendingPathComponent("notes.json")
        let notesData = try JSONEncoder().encode(notes)
        try notesData.write(to: notesURL)
        
        // Save WorldMap
        let mapURL = roomDir.appendingPathComponent("worldMap.map")
        let mapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try mapData.write(to: mapURL)
        
        print("Saved \(notes.count) notes and updated WorldMap to \(roomDir.path)")
    }

    func saveNoteImage(uuid: UUID, image: UIImage, preferredFilename: String? = nil) throws -> String {
        guard let imageData = image.pngData() else {
            throw NSError(domain: "PersistenceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode note image"])
        }

        let imagesDir = try noteImagesDirectory(uuid: uuid, createIfNeeded: true)
        let filename = preferredFilename ?? "\(UUID().uuidString).png"
        let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
        let imageURL = imagesDir.appendingPathComponent(safeFilename)
        try imageData.write(to: imageURL, options: .atomic)
        return safeFilename
    }

    func loadNoteImage(uuid: UUID, filename: String) throws -> UIImage {
        let imagesDir = try noteImagesDirectory(uuid: uuid)
        let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
        let imageURL = imagesDir.appendingPathComponent(safeFilename)
        guard let image = UIImage(contentsOfFile: imageURL.path) else {
            throw NSError(domain: "PersistenceManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to load note image"])
        }
        return image
    }

    func deleteNoteImage(uuid: UUID, filename: String) throws {
        let imagesDir = try noteImagesDirectory(uuid: uuid)
        let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
        let imageURL = imagesDir.appendingPathComponent(safeFilename)
        if fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.removeItem(at: imageURL)
        }
    }
    
    func loadWorldMap(uuid: UUID) throws -> ARWorldMap {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        let mapURL = roomDir.appendingPathComponent("worldMap.map")
        
        let mapData = try Data(contentsOf: mapURL)
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: mapData) else {
            throw NSError(domain: "PersistenceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to unarchive ARWorldMap"])
        }
        return worldMap
    }
    
    func listSavedRooms() -> [(UUID, String)] {
        guard let urls = try? fileManager.contentsOfDirectory(at: roomsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return urls.compactMap { url in
            guard let uuid = UUID(uuidString: url.lastPathComponent) else { return nil }
            let name = getRoomMetadata(uuid: uuid)?.name ?? "Room \(uuid.uuidString.prefix(4))"
            return (uuid, name)
        }
    }
    
    func roomExists(uuid: UUID) -> Bool {
        let roomDir = roomsDirectory.appendingPathComponent(uuid.uuidString)
        return fileManager.fileExists(atPath: roomDir.path)
    }
}
