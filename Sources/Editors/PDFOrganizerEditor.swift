import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// `PageSorterEditor`: reorder, rotate, duplicate or remove pages.
struct PageSorterEditor: View {
    @ObservedObject var model: ToolEditorModel
    @State private var document: PDFDocument?
    @State private var thumbnails: [Int: NSImage] = [:]
    /// Each slot is a source page index; rotations are keyed by slot id.
    @State private var slots: [Slot] = []
    @State private var selection: Set<UUID> = []

    struct Slot: Identifiable, Equatable { let id = UUID(); var page: Int; var rotation = 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(slots.count == 1 ? "1 page" : "\(slots.count) pages").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                EditorButton(title: "Reset Order") { reset() }.accessibilityIdentifier("pageSorterReset")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        page(slot, index: index)
                            .onDrag { NSItemProvider(object: slot.id.uuidString as NSString) }
                            .onDrop(of: [UTType.plainText], delegate: PageReorderDrop(target: slot, slots: $slots))
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .accessibilityIdentifier("pageSorterGrid")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Match page widths", isOn: $model.options.matchPageWidths).toggleStyle(.checkbox).font(.system(size: 13))
                    .accessibilityIdentifier("pageSorterMatchWidths")
                Text("Wider pages shrink to the narrowest one. Heights can still differ.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .task { load() }
        .onChange(of: slots) { _ in sync() }
    }

    private func page(_ slot: Slot, index: Int) -> some View {
        ZStack(alignment: .top) {
            Group {
                if let image = thumbnails[slot.page] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                else { Color.white }
            }
            .rotationEffect(.degrees(Double(slot.rotation)))
            .frame(width: 130, height: 170)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(Color(nsColor: Brand.accent)))
                Spacer()
                Button { rotate(slot, 90) } label: {
                    Image(systemName: "rotate.right").font(.system(size: 11)).foregroundStyle(.primary)
                        .frame(width: 24, height: 24).background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                }
                .buttonStyle(.plain).help("Rotate page \(index + 1) 90° clockwise")
            }
            .padding(8)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .contextMenu {
            Button("Rotate Left") { rotate(slot, -90) }
            Button("Duplicate Page") { selection = [slot.id]; duplicate() }
            Button("Remove Page") { if slots.count > 1 { slots.removeAll { $0.id == slot.id } } }.disabled(slots.count <= 1)
        }
        .accessibilityLabel("Now page \(index + 1), was page \(slot.page + 1)")
    }

    private func rotate(_ slot: Slot, _ degrees: Int) {
        guard let i = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[i].rotation = ((slots[i].rotation + degrees) % 360 + 360) % 360
    }

    private func load() {
        guard let doc = try? PDFConverter.open(model.primaryFile) else { model.message = "This PDF is unreadable or locked."; return }
        document = doc
        reset()
        Task {
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { thumbnails[i] = page.thumbnail(of: CGSize(width: 220, height: 280), for: .cropBox) }
                await Task.yield()
            }
        }
    }
    private func reset() { slots = (0..<(document?.pageCount ?? 0)).map { Slot(page: $0) }; selection = [] }
    private func duplicate() {
        var result: [Slot] = []
        for slot in slots {
            result.append(slot)
            if selection.contains(slot.id) { var copy = Slot(page: slot.page); copy.rotation = slot.rotation; result.append(copy) }
        }
        slots = result
    }
    private func sync() {
        model.options.pageSequence = slots.map(\.page)
        model.options.pageTurns = Dictionary(uniqueKeysWithValues: slots.enumerated().compactMap { $0.element.rotation == 0 ? nil : ($0.offset, $0.element.rotation) })
    }
}

/// `PDFPageDropDelegate`: live reordering while dragging a page.
struct PageReorderDrop: DropDelegate {
    let target: PageSorterEditor.Slot
    @Binding var slots: [PageSorterEditor.Slot]
    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idText = object as? String, let id = UUID(uuidString: idText) else { return }
            DispatchQueue.main.async {
                guard let from = slots.firstIndex(where: { $0.id == id }), let to = slots.firstIndex(where: { $0.id == target.id }), from != to else { return }
                withAnimation(.easeInOut(duration: 0.15)) { slots.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
            }
        }
    }
    func performDrop(info: DropInfo) -> Bool { true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
