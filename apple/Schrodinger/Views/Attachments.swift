import SwiftUI
import SwiftData
import ImageIO
import UniformTypeIdentifiers

// Photos and links attached to an item: the row of thumbnails and link chips shown under the item, the full-size
// viewer, and the image helpers. Photos are stored downscaled as JPEG; links are stored as text.

/// Decodes a stored photo to the size needed. Uses ImageIO so the same code runs on iOS and macOS.
struct AttachmentImage: View {
    let attachment: Attachment
    /// Longest side to decode, in pixels.
    let maxPixel: Int
    var fill = true
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                if fill { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                else { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            } else {
                Color.ink.opacity(0.08)
            }
        }
        .task(id: attachment.id) {
            guard !attachment.isDeleted, attachment.modelContext != nil else { return }
            image = attachment.data.flatMap { Self.thumbnail($0, maxPixel: maxPixel) }
        }
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respect the photo's orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// A picked photo, reduced to at most `maxPixel` on its longest side and re-encoded as JPEG, so a library photo
    /// of many megabytes is stored as a few hundred kilobytes. Returns nil if the data is not an image.
    static func downscaled(_ data: Data, maxPixel: Int = 2048) -> Data? {
        guard let cg = thumbnail(data, maxPixel: maxPixel) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// The item's photos and links in one row under its text: photo thumbnails, then link chips. Tap a photo to view it,
/// tap a link to open it. While the item's sheet is open (`editing`), one can be removed: on the Mac a remove button
/// shows while the pointer is over it; everywhere, hold it (or right-click) for a menu with Remove.
struct AttachmentStrip: View {
    let items: [Attachment]
    var editing = false
    let onOpen: (Attachment) -> Void
    let onDelete: (Attachment) -> Void
    /// The row does not scroll sideways (a sideways drag on a row indents it), so only the first few are shown.
    private let limit = 5
    /// The one the pointer is over (Mac).
    @State private var hovered: UUID? = nil

    var body: some View {
        let live = items.filter { !$0.isDeleted && $0.modelContext != nil }
        HStack(spacing: 8) {
            ForEach(live.prefix(limit)) { a in
                Button { onOpen(a) } label: { cell(a) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if editing {
                            Button(role: .destructive) { onDelete(a) } label: { Label(a.kind == .photo ? "Remove Photo" : "Remove Link", systemImage: "trash") }
                        }
                    }
                    #if os(macOS)
                    .onHover { inside in if inside { hovered = a.id } else if hovered == a.id { hovered = nil } }
                    #endif
                    .overlay(alignment: .topTrailing) {
                        if editing && hovered == a.id {
                            Button { onDelete(a) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(Color.canvas)
                                    .frame(width: 18, height: 18)
                                    .background(Color.ink, in: Circle())
                                    .frame(width: 30, height: 30).contentShape(Rectangle())   // touch target
                            }
                            .buttonStyle(.plain)
                            .offset(x: 12, y: -12)
                            .accessibilityLabel(a.kind == .photo ? "Remove photo" : "Remove link")
                        }
                    }
            }
            if live.count > limit {
                Text("+\(live.count - limit)").font(.caption.weight(.semibold)).foregroundStyle(Color.ink.opacity(0.6))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func cell(_ a: Attachment) -> some View {
        switch a.kind {
        case .photo:
            AttachmentImage(attachment: a, maxPixel: 160)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .accessibilityLabel("Photo")
        case .link:
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                Text(a.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: 150)
            .fixedSize(horizontal: true, vertical: false)
            .background(Color.ink.opacity(0.07), in: Capsule())
            .foregroundStyle(Color.ink.opacity(0.85))
            .contentShape(Capsule())
            .accessibilityLabel("Link: " + a.displayTitle)
        case .item:
            EmptyView()   // links between items are listed by ItemLinkList, not here
        }
    }
}

/// One photo, full size, with Remove and Done.
struct AttachmentViewer: View {
    let attachment: Attachment
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AttachmentImage(attachment: attachment, maxPixel: 2048, fill: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .destructive) { onDelete() } label: { Label("Remove", systemImage: "trash") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
