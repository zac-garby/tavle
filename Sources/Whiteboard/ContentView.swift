import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A picked video, copied somewhere we can read it.
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Movie(url: dst)
        }
    }
}

/// Loads picked photos (in selection order).
func loadImages(_ items: [PhotosPickerItem]) async -> (images: [UIImage], failed: Int) {
    var out: [UIImage] = [], failed = 0
    for item in items {
        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { out.append(img) } else { failed += 1 }
    }
    return (out, failed)
}

/// Home: the history of boards grouped by date (searchable), with floating Import and Scan buttons (along the
/// bottom in portrait, down the side in landscape). Cards flow into as many columns as fit.
struct ContentView: View {
    @Environment(BoardStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var path: [UUID] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickedVideo: PhotosPickerItem?
    @State private var choosingPhotos = false
    @State private var choosingVideo = false
    @State private var busy: String?
    @State private var errorMessage: String?
    @State private var scanning = false
    @State private var query = ""
    @State private var searching = false
    @State private var renaming: Board?
    @State private var newTitle = ""
    @State private var deleting: Board?

    static let maxPhotos = 8
    private var canScan: Bool { CaptureModel.isSupported || isPreview }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.boards.isEmpty { emptyState } else { list }
            }
            .background(Color.black)
            .navigationTitle("Whiteboards")
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer, prompt: "Search boards")
            .navigationDestination(for: UUID.self) { BoardView(id: $0) }
            .safeAreaInset(edge: .bottom) { if !searching && verticalSize != .compact { dock } }
            .safeAreaInset(edge: .trailing) { if !searching && verticalSize == .compact { sideDock } }
            .overlay {
                if let busy {
                    VStack(spacing: 12) { ProgressView().tint(.white); Text(busy).font(.callout) }
                        .padding(24).glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .alert("Something went wrong", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("Rename", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let b = renaming, !newTitle.isEmpty { store.rename(b, newTitle) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this board and its photos?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let b = deleting { store.delete(b) } }
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $picked, maxSelectionCount: Self.maxPhotos,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .photosPicker(isPresented: $choosingVideo, selection: Binding(get: { pickedVideo.map { [$0] } ?? [] }, set: { pickedVideo = $0.first }),
                      maxSelectionCount: 1, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: picked) { _, items in if !items.isEmpty { importPhotos(items) } }
        .onChange(of: pickedVideo) { _, item in if let item { importVideo(item) } }
        .fullScreenCover(isPresented: $scanning) {
            #if DEBUG
            if Screenshots.active { Screenshots.capture(store) } else { captureView }
            #else
            captureView
            #endif
        }
        #if DEBUG
        .task { loadDebugInputs() }
        #endif
    }

    private var captureView: some View {
        CaptureView(onFinish: { result in
            scanning = false
            switch result {
            case .scan(let dir): importScan(dir)
            case .photos(let images): importCapturedPhotos(images)
            }
        }, onCancel: { scanning = false })
    }

    // MARK: list

    private var filtered: [Board] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.boards : store.boards.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !searching {
                    Text(summary).font(.subheadline).foregroundStyle(Theme.secondaryText).padding(.horizontal, 8).padding(.top, -6)
                }
                ForEach(BoardSection.group(filtered)) { section in
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title).font(.title3.bold())
                        Spacer()
                        Text("\(section.boards.count) board\(section.boards.count == 1 ? "" : "s")")
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, 8).padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                    // Portrait: big cards one per row, compact ones two per row; landscape fits more of each.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: section.compact ? 165 : 300), spacing: 10)], spacing: 10) {
                        ForEach(section.boards) { card($0, compact: section.compact) }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 40)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden, axes: .vertical)
    }

    private var summary: String {
        let photos = store.boards.reduce(0) { $0 + $1.photos.count }
        return "\(store.boards.count) board\(store.boards.count == 1 ? "" : "s") · \(photos) photo\(photos == 1 ? "" : "s")"
    }

    private func card(_ b: Board, compact: Bool) -> some View {
        NavigationLink(value: b.id) { BoardCard(board: b, compact: compact) }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename", systemImage: "pencil") { newTitle = b.title; renaming = b }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = b }
            }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No boards yet", systemImage: "rectangle.split.3x1")
        } description: {
            Text(canScan
                 ? "Tap the shutter to scan a whiteboard, or import overlapping photos or a video sweeping along it."
                 : "Import 2–\(Self.maxPhotos) overlapping photos (tap them left to right), or a video sweeping along the board.")
        }
    }

    // MARK: dock

    private var importMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Video", systemImage: "video") { choosingVideo = true }
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
        }
        .accessibilityLabel("Import photos or video")
    }

    private var dock: some View {
        HStack {
            importMenu.menuStyle(.button).buttonStyle(.glassCircle)
            Spacer()
            if canScan {
                Button { scanning = true } label: { ShutterLabel(progress: 1, icon: "viewfinder") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan a board")
            }
            Spacer()
            Color.clear.frame(width: 52, height: 52)   // balances the import button; search lives in the nav bar
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(alignment: .bottom) {
            // Fade the list out under the floating buttons.
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -24).ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
        }
    }

    /// Landscape: the same buttons in a column at the trailing edge, scan in the middle like the camera app.
    private var sideDock: some View {
        VStack(spacing: 24) {
            if canScan {
                Button { scanning = true } label: { ShutterLabel(progress: 1, size: 68, icon: "viewfinder") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan a board")
            }
            importMenu.menuStyle(.button).buttonStyle(.glassCircle)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 12)
        .background(alignment: .trailing) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                .padding(.leading, -24).ignoresSafeArea().allowsHitTesting(false)
        }
    }

    // MARK: inputs

    private func importPhotos(_ items: [PhotosPickerItem]) {
        busy = "Loading photos…"
        Task {
            let (images, failed) = await loadImages(items)
            picked = []
            do {
                if !images.isEmpty { path.append(try store.create(images: images, source: .photos).id) }
                if failed > 0 { errorMessage = "\(failed) photo(s) couldn't be loaded." }
            } catch { errorMessage = error.localizedDescription }
            busy = nil
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        busy = "Loading video…"
        Task {
            defer { pickedVideo = nil; busy = nil }
            do {
                guard let movie = try await item.loadTransferable(type: Movie.self) else { throw VideoKeyframeExtractor.ExtractError.unreadable }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                busy = "Finding frames…"
                let frames = try await VideoKeyframeExtractor().extract(from: movie.url)
                path.append(try store.create(images: frames, source: .video).id)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// 0.5× captures: already ordered left -> right; no poses, so they go through the image-only pipeline.
    private func importCapturedPhotos(_ images: [UIImage]) {
        do {
            let b = try store.create(images: images, source: .scan)
            path.append(b.id)
            Task { await store.process(b.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func importScan(_ dir: URL, copy: Bool = false) {
        do {
            let b = try store.create(scan: dir, copy: copy)
            path.append(b.id)
            Task { await store.process(b.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    #if DEBUG
    /// Simulator conveniences (each makes a new board):
    ///   -WBPhotos /abs/dir    that folder's images, sorted by name; add -WBAutoRun YES to flatten
    ///   -WBVideo /abs/file    frames from a video
    ///   -WBCapture /abs/dir   a guided scan copied off the phone (Files > Whiteboard > Boards/<id>)
    private func loadDebugInputs() {
        let d = UserDefaults.standard
        if Screenshots.active {
            Task {
                await Screenshots.build(store)
                let boards = Screenshots.boards(store)
                switch Screenshots.scene {
                case .home: break
                case .capture: scanning = true
                case .board, .edit, .photos: if boards.indices.contains(Screenshots.openIndex) { path = [boards[Screenshots.openIndex].id] }
                }
            }
            return
        }
        if let dir = d.string(forKey: "WBCapture") { importScan(URL(fileURLWithPath: dir), copy: true); return }
        if let file = d.string(forKey: "WBVideo") {
            busy = "Finding frames…"
            Task {
                do { path.append(try store.create(images: try await VideoKeyframeExtractor().extract(from: URL(fileURLWithPath: file)), source: .video).id) }
                catch { errorMessage = error.localizedDescription }
                busy = nil
            }
            return
        }
        guard let dir = d.string(forKey: "WBPhotos"), let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let images = names.sorted().compactMap { UIImage(contentsOfFile: (dir as NSString).appendingPathComponent($0)) }
        guard !images.isEmpty, let b = try? store.create(images: images, source: .photos) else { return }
        path.append(b.id)
        if d.bool(forKey: "WBAutoRun") { Task { await store.process(b.id) } }
    }
    #endif
}

/// A board in the history: its picture (framed, cropped and enhanced as last left) edge to edge on top,
/// title / time / status below.
struct BoardCard: View {
    @Environment(BoardStore.self) private var store
    let board: Board
    var compact = false
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
                .frame(height: compact ? 70 : 128)
                .frame(maxWidth: .infinity)
                .clipped()
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(board.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    StatusBadge(board: board, stage: store.progress[board.id]).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.title).font(.headline).lineLimit(1)
                        Text("\(board.created.formatted(date: .omitted, time: .shortened)) · \(board.photoCountText)")
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    StatusBadge(board: board, stage: store.progress[board.id])
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .task(id: board) { cover = await store.cover(board) }
    }

    @ViewBuilder private var thumbnail: some View {
        if let t = store.cachedCover(board) ?? cover ?? store.listThumbnail(board) {
            Image(uiImage: t).resizable().scaledToFill()
                .saturation(board.isDone ? 1 : 0.4)
        } else {
            ZStack { Color(white: 0.18); Image(systemName: "rectangle.split.3x1").foregroundStyle(Theme.secondaryText) }
        }
    }
}

/// Previews (and -WBSamples / -WBShots in the simulator) show the scan button even without ARKit.
private var isPreview: Bool {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "WBSamples") || Screenshots.active { return true }
    #endif
    return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

#if DEBUG
#Preview("Home") {
    ContentView().environment(BoardStore.preview()).preferredColorScheme(.dark).tint(Theme.accent)
}

#Preview("Home – empty") {
    ContentView().environment(BoardStore.preview(empty: true)).preferredColorScheme(.dark).tint(Theme.accent)
}
#endif
