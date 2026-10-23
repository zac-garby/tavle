import CoreTransferable
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoLibrary {
    static let albumTitle = "Whiteboards"
    private static let albumKey = "WhiteboardsAlbumID"

    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Allow photo access in Settings to save boards." }
    }

    /// Saves JPEG data to Photos, in the "Whiteboards" album if we're allowed to see albums (full or limited
    /// access); with add-only access it lands in Recents. Returns true if it went into the album.
    @discardableResult
    static func save(_ data: Data) async throws -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            // Maybe they'll still allow add-only.
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw SaveError.denied }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return false
        }
        let album = try await whiteboardsAlbum()
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            if let album, let placeholder = req.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        return album != nil
    }

    /// Finds the album (by remembered id, then by title) or creates it.
    private static func whiteboardsAlbum() async throws -> PHAssetCollection? {
        if let id = UserDefaults.standard.string(forKey: albumKey),
           let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject { return c }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", albumTitle)
        if let c = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject {
            UserDefaults.standard.set(c.localIdentifier, forKey: albumKey)
            return c
        }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id else { return nil }
        UserDefaults.standard.set(id, forKey: albumKey)
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", png = "PNG", pdf = "PDF"
    var id: String { rawValue }
    var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .pdf: .pdf } }
    var ext: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .pdf: "pdf" } }

    func data(for image: UIImage) -> Data? {
        switch self {
        case .jpeg: return image.jpegData(compressionQuality: 0.92)
        case .png: return image.pngData()
        case .pdf: return Self.pdf(image)
        }
    }

    /// One page the shape of the board (long side 1190 pt ≈ A3), image embedded as JPEG.
    static func pdf(_ image: UIImage) -> Data? {
        guard let jpeg = image.jpegData(compressionQuality: 0.92), let embedded = UIImage(data: jpeg) else { return nil }
        let s = 1190 / max(image.size.width, image.size.height)
        let page = CGRect(x: 0, y: 0, width: image.size.width * s, height: image.size.height * s)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            ctx.beginPage()
            embedded.draw(in: page)
        }
    }
}

/// Lazily encoded export for ShareLink.
struct ExportItem: Transferable {
    let image: UIImage
    let format: ExportFormat
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg, exporting: export).exportingCondition { $0.format == .jpeg }
        FileRepresentation(exportedContentType: .png, exporting: export).exportingCondition { $0.format == .png }
        FileRepresentation(exportedContentType: .pdf, exporting: export).exportingCondition { $0.format == .pdf }
    }

    @Sendable static func export(_ item: ExportItem) async throws -> SentTransferredFile {
        guard let data = item.format.data(for: item.image) else { throw CocoaError(.fileWriteUnknown) }
        let safe = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).\(item.format.ext)")
        try data.write(to: url, options: .atomic)
        return SentTransferredFile(url)
    }
}
