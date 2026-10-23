#if DEBUG
import SwiftUI

/// App Store screenshots: `scripts/screenshots.py` launches the simulator build with
///   -WBShots /abs/dir     boards from dir's subfolders, in name order (newest first on the home screen). A folder
///                         is photos (sorted by name) or a guided scan copied off the phone (has capture.json).
///                         "01 Type theory" -> title "Type theory". Optional look.json:
///                         {"framing": "content", "enhancement": "whiten", "hoursAgo": 26, "trim": [x, y, w, h]}
///                         Optional dir/capture.jpg: the camera picture behind the capture screen.
///   -WBShotsRebuild YES   flatten them again (writes Application Support/Screenshots/ready when done)
///   -WBScene home|board|edit|photos|capture   and -WBOpen <n>: which board (0 = first folder)
/// The boards live apart from the real history, with their own last-look defaults.
enum Screenshots {
    enum Scene: String { case home, board, edit, photos, capture }

    struct Look: Decodable {
        var framing: Board.Framing?
        var enhancement: String?   // original | whiten | scan
        var hoursAgo: Double?
        var trim: [Double]?
    }

    private static let d = UserDefaults.standard
    static var input: URL? { d.string(forKey: "WBShots").map { URL(fileURLWithPath: $0) } }
    static var active: Bool { input != nil }
    static var scene: Scene { d.string(forKey: "WBScene").flatMap(Scene.init) ?? .home }
    static var openIndex: Int { d.integer(forKey: "WBOpen") }
    static let root = URL.applicationSupportDirectory.appendingPathComponent("Screenshots")

    /// Spread over today / yesterday / this week / earlier so the home screen shows its sections.
    private static let defaultHoursAgo: [Double] = [2, 5, 27, 52, 100, 170, 400, 900]

    static func makeStore() -> BoardStore {
        if d.bool(forKey: "WBShotsRebuild") { try? FileManager.default.removeItem(at: root) }
        return BoardStore(root: root.appendingPathComponent("Boards"), defaults: UserDefaults(suiteName: "WBScreenshots")!)
    }

    private static func folders() -> [URL] {
        guard let input else { return [] }
        let all = (try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Boards in folder order (the store's is by date, which look.json can change).
    static func boards(_ store: BoardStore) -> [Board] {
        folders().compactMap { f in store.boards.first { $0.title == title(f) } }
    }

    private static func title(_ folder: URL) -> String {
        let name = folder.lastPathComponent
        guard let r = name.range(of: #"^\d+[ _-]+"#, options: .regularExpression) else { return name }
        return String(name[r.upperBound...])
    }

    /// Imports and flattens every folder, unless that's already been done.
    @MainActor static func build(_ store: BoardStore) async {
        guard store.boards.isEmpty else { return }
        let imageTypes: Set = ["jpg", "jpeg", "png", "heic"]
        for (i, folder) in folders().enumerated() {
            let fm = FileManager.default
            let look = (try? Data(contentsOf: folder.appendingPathComponent("look.json")))
                .flatMap { try? JSONDecoder().decode(Look.self, from: $0) }
            let b: Board?
            if fm.fileExists(atPath: folder.appendingPathComponent(CaptureRecord.fileName).path) {
                b = try? store.create(scan: folder, copy: true)
            } else {
                let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                    .filter { imageTypes.contains(($0 as NSString).pathExtension.lowercased()) }
                let images = names.compactMap { UIImage(contentsOfFile: folder.appendingPathComponent($0).path) }
                b = images.isEmpty ? nil : try? store.create(images: images, source: .photos)
            }
            guard var b else { continue }
            b.title = title(folder)
            b.created = Date.now.addingTimeInterval(-3600 * (look?.hoursAgo ?? defaultHoursAgo[min(i, defaultHoursAgo.count - 1)]))
            store.save(b)
            await store.process(b.id)
            guard var done = store.board(b.id) else { continue }
            if let f = look?.framing { done.framing = f }
            if let e = Board.Enhancement.allCases.first(where: { "\($0)" == look?.enhancement }) { done.enhancement = e }
            if let t = look?.trim, t.count == 4 { done.trims[done.framing.rawValue] = t }
            store.save(done)
        }
        store.reload()
        try? Data().write(to: root.appendingPathComponent("ready"))
    }

    /// The capture screen frozen mid-sweep over a still picture (no camera in the simulator).
    static func capture(_ store: BoardStore) -> some View {
        let first = boards(store).first
        let photos = first.map { b in b.photos.map { store.file(b, $0) } } ?? []
        let custom = input?.appendingPathComponent("capture.jpg")
        let backdrop = custom.flatMap { UIImage(contentsOfFile: $0.path) }
            ?? photos.dropFirst(photos.count / 2).first.flatMap { UIImage(contentsOfFile: $0.path) }
        let taken = photos.prefix(max(1, (photos.count + 1) / 2)).compactMap { store.thumbnail($0) }
        return CaptureView.still(backdrop: backdrop, thumbnails: taken)
    }
}
#endif
