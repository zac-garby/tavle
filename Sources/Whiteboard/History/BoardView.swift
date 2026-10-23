import PhotosUI
import SwiftUI

/// One board: the flattened result edge to edge, Save underneath and an edit panel (framing, crop handles, look)
/// that folds away. In landscape the controls move to the side. Drafts and failed boards show what's wrong and
/// lead to the photos.
struct BoardView: View {
    let id: UUID
    @Environment(BoardStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize

    @State private var base: UIImage?    // the framing's image in the board's look, before the user's crop
    @State private var image: UIImage?   // what's shown, saved and shared
    @State private var looks: [Board.Enhancement: UIImage] = [:]
    @State private var editing = false
    @State private var toast: String?
    @State private var showPhotos = false
    @State private var showWarnings = false
    @State private var editingCorners = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    private var landscape: Bool { verticalSize == .compact }

    var body: some View {
        if let b = store.board(id) {
            content(b)
        } else {
            ContentUnavailableView("Board deleted", systemImage: "trash")
        }
    }

    private func content(_ b: Board) -> some View {
        let processing = store.progress[b.id]
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            main(b, processing: processing).frame(maxWidth: .infinity, maxHeight: .infinity)
            if b.isDone && processing == nil { controls(b) }
        }
        .animation(.snappy(duration: 0.3), value: editing)
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(b) }
        .navigationDestination(isPresented: $showPhotos) { BoardPhotosView(id: b.id) }
        .task(id: BaseKey(b: b, busy: processing != nil)) {
            base = nil
            image = nil
            guard b.isDone else { return }
            base = await store.result(b, framing: b.framing, enhancement: b.enhancement)
            image = base?.trimmed(b.trim(b.framing))
        }
        .onChange(of: b.trim(b.framing)) { _, t in image = base?.trimmed(t) }
        .task(id: LooksKey(b: b)) { looks = b.isDone ? await store.lookPreviews(b) : [:] }
        .fullScreenCover(isPresented: $editingCorners) { CornerEditor(board: b) }
        .sheet(isPresented: $showWarnings) { WarningsSheet(board: b) }
        #if DEBUG
        .onChange(of: b.isDone) { _, done in   // -WBCorners YES: open the corner editor once flattened (simulator checks)
            if done, UserDefaults.standard.bool(forKey: "WBCorners") { editingCorners = true }
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "WBEditing") || Screenshots.active && Screenshots.scene == .edit { editing = true }   // -WBEditing YES: open the edit panel
            if Screenshots.active && Screenshots.scene == .photos { showPhotos = true }
        }
        #endif
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { if !newTitle.isEmpty { store.rename(b, newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this board and its photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(b); dismiss() }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: toast)
    }

    /// What the uncropped image depends on (reloaded after flattening again, too).
    private struct BaseKey: Hashable {
        var status: Board.Status, corners: [[Double]]?, rect: [Double]?, framing: Board.Framing, enhancement: Board.Enhancement, busy: Bool
        init(b: Board, busy: Bool) {
            status = b.status; corners = b.corners; rect = b.croppedRect; framing = b.framing; enhancement = b.enhancement; self.busy = busy
        }
    }
    /// Look previews depend on the board crop, not on which look is selected.
    private struct LooksKey: Hashable {
        var status: Board.Status, corners: [[Double]]?, rect: [Double]?
        init(b: Board) { status = b.status; corners = b.corners; rect = b.croppedRect }
    }

    // MARK: main area

    @ViewBuilder private func main(_ b: Board, processing: String?) -> some View {
        if let processing {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(processing + "…").font(.headline)
                Text(b.photoCountText).font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
        } else if let failure = b.failure {
            ContentUnavailableView {
                Label("Couldn't flatten", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Look at the photos") { showPhotos = true }.buttonStyle(.primary).frame(width: 240)
            }
        } else if !b.isDone {
            ContentUnavailableView {
                Label("Not flattened yet", systemImage: "rectangle.split.3x1")
            } description: {
                Text(b.photoCountText)
            } actions: {
                Button("Flatten board") { flatten(b) }.buttonStyle(.primary).frame(width: 240).disabled(b.photos.isEmpty)
                Button("Look at the photos") { showPhotos = true }
            }
        } else if editing, let base {
            TrimEditor(image: base, trim: b.trim(b.framing)) { store.setTrim(b, b.framing, $0) }
                .transition(.opacity)
        } else if let image {
            ZStack(alignment: .bottom) {
                ZoomableImage(image: image)
                notices(b).padding(.bottom, 12)
            }
            .transition(.opacity)
        } else {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func notices(_ b: Board) -> some View {
        let leftOut = b.leftOut?.count ?? 0
        if !b.warnings.isEmpty || leftOut > 0 {
            HStack(spacing: 8) {
                if !b.warnings.isEmpty {
                    Button { showWarnings = true } label: {
                        Label("\(b.warnings.count) warning\(b.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(ChipStyle(color: Theme.warning))
                }
                if leftOut > 0 {
                    Button { showPhotos = true } label: {
                        Label("\(leftOut) photo\(leftOut == 1 ? "" : "s") left out", systemImage: "photo.badge.exclamationmark")
                    }
                    .buttonStyle(ChipStyle(color: .white))
                }
            }
        }
    }

    // MARK: controls

    /// Portrait: a strip under the image. Landscape: a column beside it (a slim rail while folded away).
    @ViewBuilder private func controls(_ b: Board) -> some View {
        if landscape {
            VStack(spacing: 16) {
                if editing {
                    editPanel(b, tile: 84)
                    HStack(spacing: 12) { secondaryButton(b); primaryButton(b) }
                } else {
                    secondaryButton(b)
                    Button { if let image { save(image) } } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.primaryCircle)
                        .disabled(image == nil)
                        .accessibilityLabel("Save to Photos")
                }
            }
            .frame(width: editing ? 296 : nil)
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            VStack(spacing: 18) {
                if editing { editPanel(b, tile: 100).transition(.move(edge: .bottom).combined(with: .opacity)) }
                HStack(spacing: 12) { secondaryButton(b); primaryButton(b) }.padding(.horizontal, 16)
            }
            .padding(.top, editing ? 16 : 8)
            .padding(.bottom, 8)
        }
    }

    private func editPanel(_ b: Board, tile: CGFloat) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: landscape ? 12 : 22) {
                ForEach(Board.Framing.allCases) { f in
                    FramingButton(framing: f, hasCorners: b.corners != nil, cropped: b.trim(f) != Board.wholeImage,
                                  selected: b.framing == f) { store.setFraming(b, f) }
                }
            }
            HStack(spacing: landscape ? 8 : 10) {
                ForEach(Board.Enhancement.allCases) { e in
                    LookTile(label: e.label, image: looks[e], width: tile, selected: b.enhancement == e) { store.setEnhancement(b, e) }
                }
            }
        }
    }

    /// Edit while the panel is folded away; while editing, undo this framing's crop.
    @ViewBuilder private func secondaryButton(_ b: Board) -> some View {
        if editing {
            Button { store.setTrim(b, b.framing, Board.wholeImage) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.glassCircle(size: 54))
                .disabled(b.trim(b.framing) == Board.wholeImage)
                .accessibilityLabel("Undo crop")
        } else {
            Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.glassCircle(size: 54))
                .accessibilityLabel("Edit")
        }
    }

    @ViewBuilder private func primaryButton(_ b: Board) -> some View {
        if editing {
            Button("Done") { editing = false }.buttonStyle(.primary)
        } else {
            Button { if let image { save(image) } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                .buttonStyle(.primary)
                .disabled(image == nil)
        }
    }

    private func shareMenu(_ b: Board) -> some View {
        Menu {
            if let image {
                ForEach(ExportFormat.allCases) { f in
                    ShareLink(item: ExportItem(image: image, format: f, name: b.title),
                              preview: SharePreview(b.title, image: Image(uiImage: image))) { Text(f.rawValue) }
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(image == nil)
    }

    @ToolbarContentBuilder private func toolbar(_ b: Board) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(b.title).font(.headline).lineLimit(1)
                if !landscape {   // the landscape bar has room for one line
                    Text("\(b.whenText()) · \(b.photoCountText)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Photos", systemImage: "photo.stack") { showPhotos = true }
            if b.isDone { shareMenu(b) }
            Menu {
                if b.isDone { Button("Adjust corners", systemImage: "crop") { editingCorners = true } }
                Button("Flatten again", systemImage: "arrow.clockwise") { flatten(b) }.disabled(b.photos.isEmpty)
                Button("Rename", systemImage: "pencil") { newTitle = b.title; renaming = true }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: { Label("More", systemImage: "ellipsis") }
            .disabled(store.progress[b.id] != nil)
        }
    }

    // MARK: actions

    private func flatten(_ b: Board) { Task { await store.process(b.id) } }

    private func save(_ img: UIImage) {
        Task {
            guard let data = img.jpegData(compressionQuality: 0.92) else { return }
            do {
                let inAlbum = try await PhotoLibrary.save(data)
                flash(inAlbum ? "Saved to \(PhotoLibrary.albumTitle)" : "Saved to Photos")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    private func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(2)); if toast == s { toast = nil } }
    }
}

// MARK: - tool controls

/// Round framing tool, Photos-edit style: an outline glyph in a ring; green when selected.
private struct FramingButton: View {
    let framing: Board.Framing
    let hasCorners: Bool
    let cropped: Bool       // the user has cropped this framing further
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if cropped { Circle().fill(Theme.accent).frame(width: 10, height: 10).offset(x: -2, y: 2) }
                    }
                Text(label).font(.caption.weight(.semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Color(white: 0.78))
            .frame(minWidth: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(cropped ? "Cropped" : "")
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var label: String {
        switch framing { case .board: hasCorners ? "Corners" : "Board"; case .content: "Content"; case .full: "Everything" }
    }
    private var icon: String {
        switch framing { case .board: hasCorners ? "crop" : "rectangle"; case .content: "text.viewfinder"; case .full: "rectangle.dashed" }
    }
}

/// A look (Original / Whiten / B&W) previewed on the board itself.
private struct LookTile: View {
    let label: String
    let image: UIImage?
    var width: CGFloat = 100
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(white: 0.2) }
                }
                .frame(width: width, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(selected ? Theme.accent : Color(white: 0.78))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// Small tinted capsule over the image ("2 warnings", "1 photo left out").
private struct ChipStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .glass(in: Capsule(), interactive: true)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct WarningsSheet: View {
    let board: Board
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(board.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
            .navigationTitle("Warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - photos

/// The board's source photos, left to right: inspect, reorder, delete, add, flatten again.
struct BoardPhotosView: View {
    let id: UUID
    @Environment(BoardStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var addPicked: [PhotosPickerItem] = []

    var body: some View {
        if let b = store.board(id) { list(b) } else { ContentUnavailableView("Board deleted", systemImage: "trash") }
    }

    private func list(_ b: Board) -> some View {
        let processing = store.progress[b.id]
        return List {
            if let failure = b.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure).font(.callout)
                    Text("Tap a photo to look at it. Delete or reorder photos, then flatten again.").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            Section {
                ForEach(Array(b.photos.enumerated()), id: \.element) { i, name in
                    NavigationLink {
                        PhotoDetail(board: b, name: name, index: i)
                    } label: {
                        row(b, i, name)
                    }
                }
                .onMove { store.movePhotos(b, from: $0, to: $1) }
                .onDelete { store.removePhotos(b, at: $0) }
            } header: {
                HStack {
                    Text("Left → right")
                    Spacer()
                    Button("Reverse") { store.reversePhotos(b) }.font(.footnote.weight(.semibold)).textCase(nil)
                }
            } footer: {
                Text(b.source == .scan
                     ? "Scans are ordered by where the camera was. Photos you add have no tracking, so the board is then joined from the images alone."
                     : "Drag to reorder. Neighbouring photos should overlap by about a third.")
            }
            Section {
                PhotosPicker(selection: $addPicked, maxSelectionCount: 8, selectionBehavior: .ordered, matching: .images) {
                    Label("Add photos", systemImage: "plus")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { flatten(b) } label: {
                HStack(spacing: 8) {
                    if let processing { ProgressView().tint(Theme.onAccent); Text(processing + "…") }
                    else { Text(b.isDone ? "Flatten again" : "Flatten board") }
                }
            }
            .buttonStyle(.primary)
            .disabled(processing != nil || b.photos.isEmpty)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .onChange(of: addPicked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let (imgs, _) = await loadImages(items)
                try? store.addPhotos(b, imgs)
                addPicked = []
            }
        }
    }

    private func row(_ b: Board, _ i: Int, _ name: String) -> some View {
        let leftOut = b.leftOut?.contains(name) ?? false
        return HStack(spacing: 14) {
            Group {
                if let t = store.thumbnail(store.file(b, name)) { Image(uiImage: t).resizable().scaledToFill() } else { Color(white: 0.2) }
            }
            .frame(width: 76, height: 57)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(leftOut ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo \(i + 1)").font(.body.weight(.semibold))
                if leftOut {
                    Text("Left out — didn't match its neighbours").font(.footnote).foregroundStyle(Theme.warning)
                } else if b.photos.count > 1, i == 0 || i == b.photos.count - 1 {
                    Text(i == 0 ? "Leftmost" : "Rightmost").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func flatten(_ b: Board) {
        dismiss()
        Task { await store.process(b.id) }
    }
}

struct PhotoDetail: View {
    @Environment(BoardStore.self) private var store
    let board: Board
    let name: String
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { ZoomableImage(image: image).ignoresSafeArea(edges: .bottom) } else { ProgressView().tint(.white) }
        }
        .navigationTitle("Photo \(index + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = store.file(board, name)
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.normalized(maxDimension: 4096) }.value
        }
    }
}

#if DEBUG
#Preview("Board") {
    let store = BoardStore.preview()
    return NavigationStack { BoardView(id: store.boards[0].id) }
        .environment(store).preferredColorScheme(.dark).tint(Theme.accent)
}

#Preview("Board – warnings") {
    let store = BoardStore.preview()
    return NavigationStack { BoardView(id: store.boards[1].id) }
        .environment(store).preferredColorScheme(.dark).tint(Theme.accent)
}

#Preview("Board – failed") {
    let store = BoardStore.preview()
    return NavigationStack { BoardView(id: store.boards.first { $0.failure != nil }!.id) }
        .environment(store).preferredColorScheme(.dark).tint(Theme.accent)
}

#Preview("Photos") {
    let store = BoardStore.preview()
    return NavigationStack { BoardPhotosView(id: store.boards[1].id) }
        .environment(store).preferredColorScheme(.dark).tint(Theme.accent)
}
#endif
