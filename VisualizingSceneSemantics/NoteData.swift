import Foundation
import ARKit
import RealityKit

struct NoteContentComponent: Component, Codable {
    var text: String?
    var imageFilename: String?

    init(text: String? = nil, imageFilename: String? = nil) {
        self.text = text
        self.imageFilename = imageFilename
    }
}

struct NoteData: Codable {
    let transform: simd_float4x4
    let text: String?
    // Image binary data is stored as a separate file in the room directory.
    let imageFilename: String?
    let noteRootTransform: simd_float4x4?
    
    init(transform: simd_float4x4, text: String?, imageFilename: String?, noteRootTransform: simd_float4x4? = nil) {
        self.transform = transform
        self.text = text
        self.imageFilename = imageFilename
        self.noteRootTransform = noteRootTransform
    }
}

extension simd_float4x4: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let c0 = try container.decode(simd_float4.self)
        let c1 = try container.decode(simd_float4.self)
        let c2 = try container.decode(simd_float4.self)
        let c3 = try container.decode(simd_float4.self)
        self.init(columns: (c0, c1, c2, c3))
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(columns.0)
        try container.encode(columns.1)
        try container.encode(columns.2)
        try container.encode(columns.3)
    }
}
