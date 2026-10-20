import Foundation
import ImageIO
import PDFKit

/// Reads and rewrites embedded tags for images, media and PDFs.
enum MetadataTools {
    // MARK: Read

    static func fields(for url: URL) async -> [TagEntry] {
        switch FormatCatalog.category(FormatCatalog.format(of: url) ?? "") {
        case .image: return imageFields(url)
        case .pdf: return pdfFields(url)
        case .audio, .video: return await mediaFields(url)
        default: return []
        }
    }

    /// "BitDepth" → "Bit Depth", "album_artist" → "Album Artist".
    static func label(_ key: String) -> String {
        var out = ""
        let chars = Array(key.replacingOccurrences(of: "_", with: " "))
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase { out.append(" ") }
            out.append(i == 0 ? Character(c.uppercased()) : c)
        }
        return out.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func describe(_ value: Any) -> String? {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.compactMap(describe).joined(separator: ", ")
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        default: return nil
        }
    }

    /// Every tag stored in the image, grouped like ExifTool output.
    private static func imageFields(_ url: URL) -> [TagEntry] {
        let props = ImageIOKit.properties(url)
        let format = FormatCatalog.format(of: url) ?? ""
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        var fields = [
            TagEntry(id: "file.FileType", label: "File Type", value: FormatCatalog.label(format), editable: false, group: "File", removable: false),
            TagEntry(id: "file.FileTypeExtension", label: "File Type Extension", value: FormatCatalog.label(format), editable: false, group: "File", removable: false),
            TagEntry(id: "file.MIMEType", label: "Mimetype", value: type?.preferredMIMEType ?? "", editable: false, group: "File", removable: false),
        ]
        let groups: [(String, String, String)] = [
            (kCGImagePropertyTIFFDictionary as String, "tiff", "TIFF"), (kCGImagePropertyExifDictionary as String, "exif", "Exif"),
            (kCGImagePropertyExifAuxDictionary as String, "exifaux", "Exif"), (kCGImagePropertyGPSDictionary as String, "gps", "GPS"),
            (kCGImagePropertyIPTCDictionary as String, "iptc", "IPTC"), (kCGImagePropertyPNGDictionary as String, "png", "PNG"),
            (kCGImagePropertyJFIFDictionary as String, "jfif", "JFIF"), (kCGImagePropertyHEICSDictionary as String, "heic", "HEIC"),
        ]
        for (dictionaryKey, prefix, group) in groups {
            guard let dictionary = props[dictionaryKey] as? [String: Any] else { continue }
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key].flatMap(describe), !value.isEmpty else { continue }
                let metadataTag = ["tiff", "exif", "exifaux", "gps", "iptc"].contains(prefix)
                fields.append(TagEntry(id: "\(prefix).\(key)", label: label(key), value: value,
                                            editable: metadataTag && prefix != "gps" && dictionary[key] is String, group: group, removable: metadataTag))
            }
        }
        if let w = props[kCGImagePropertyPixelWidth as String], let h = props[kCGImagePropertyPixelHeight as String] {
            fields.append(TagEntry(id: "file.ImageHeight", label: "Image Height", value: "\(h)", editable: false, group: "File", removable: false))
            fields.append(TagEntry(id: "file.ImageWidth", label: "Image Width", value: "\(w)", editable: false, group: "File", removable: false))
        }
        return fields
    }

    private static func pdfFields(_ url: URL) -> [TagEntry] {
        let attributes = PDFDocument(url: url)?.documentAttributes ?? [:]
        let editable: Set<PDFDocumentAttribute> = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute, .producerAttribute]
        let order: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creationDateAttribute,
                                             .modificationDateAttribute, .creatorAttribute, .producerAttribute]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return order.compactMap { key in
            guard let value = attributes[key] else { return nil }
            let text = (value as? Date).map(formatter.string(from:)) ?? describe(value) ?? ""
            guard !text.isEmpty else { return nil }
            let name = key == .modificationDateAttribute ? "Mod Date" : label(key.rawValue)
            return TagEntry(id: "pdf." + key.rawValue, label: name, value: text, editable: editable.contains(key), group: "Document")
        }
    }

    static let mediaKeys: [(String, String)] = [("Title", "title"), ("Artist", "artist"), ("Album", "album"), ("Album Artist", "album_artist"),
                                                ("Genre", "genre"), ("Year", "date"), ("Track", "track"), ("Composer", "composer"),
                                                ("Comments", "comment"), ("Author", "author"), ("Device", "model"), ("Location", "location")]

    /// Container tags as ffprobe reports them.
    private static func mediaFields(_ url: URL) async -> [TagEntry] {
        let tags = (try? await FFmpeg.probe(url))?.tags ?? [:]
        return tags.keys.sorted().compactMap { key in
            guard let value = tags[key], !value.isEmpty else { return nil }
            let known = mediaKeys.first { $0.1 == key }?.0
            return TagEntry(id: "ffmpeg." + key, label: known ?? label(key), value: value, group: "File tags")
        }
    }

    // MARK: Write

    static func apply(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let format = FormatCatalog.format(of: source) ?? ""
        let output = context.output(for: source, label: options.wipeAllTags ? "No Metadata" : "Edited", ext: FormatCatalog.fileExtension(format))
        let removeAll = options.wipeAllTags
        switch FormatCatalog.category(format) {
        case .image: try await writeImage(source, to: output, format: format, fields: options.tagEntries, removeAll: removeAll)
        case .pdf: try writePDF(source, to: output, fields: options.tagEntries, removeAll: removeAll)
        case .audio, .video:
            var args = ["-i", source.path, "-map", "0", "-c", "copy"]
            if removeAll {
                args += ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
            } else {
                args += ["-map_metadata", "0"]
                for field in options.tagEntries where field.id.hasPrefix("ffmpeg.") && (field.removed || field.editable) {
                    let key = String(field.id.dropFirst(7))
                    args += ["-metadata", "\(key)=\(field.removed ? "" : field.value)"]
                }
            }
            if ["mp4", "mov", "m4a"].contains(format) { args += ["-movflags", "+faststart+use_metadata_tags"] }
            args.append(output.path)
            try await FFmpeg.run(args, duration: 0, context: context)
        default:
            throw LimeError("Lime can't change this tag.")
        }
    }

    private static func writeImage(_ source: URL, to output: URL, format: String, fields: [TagEntry], removeAll: Bool) async throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(input) else {
            throw LimeError("This picture is unreadable.")
        }
        let losslessCopy = ["jpg", "png", "heic", "tiff"].contains(format)
        if losslessCopy, let writer = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let metadata: CGImageMetadata
            if removeAll {
                metadata = CGImageMetadataCreateMutable()
            } else {
                let mutable = CGImageSourceCopyMetadataAtIndex(input, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
                for field in fields { setImageField(field, in: mutable) }
                metadata = mutable
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeXMP: removeAll, kCGImageMetadataShouldExcludeGPS: removeAll || fields.contains { $0.id.hasPrefix("gps.") && $0.removed }]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(writer, input, options as CFDictionary, &error) { return }
            try? FileManager.default.removeItem(at: output)
        }
        // Formats without lossless metadata rewriting are re-encoded at top quality.
        let image = try ImageIOKit.load(source)
        var props: [String: Any] = [:]
        if !removeAll {
            props = ImageIOKit.portableMetadata(source)
            for field in fields where field.removed {
                let parts = field.id.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "gps" { props.removeValue(forKey: kCGImagePropertyGPSDictionary as String); continue }
                let dictionary = ["tiff": kCGImagePropertyTIFFDictionary, "exif": kCGImagePropertyExifDictionary, "iptc": kCGImagePropertyIPTCDictionary][parts[0]]
                if let dictionary, var values = props[dictionary as String] as? [String: Any] {
                    values.removeValue(forKey: parts[1]); props[dictionary as String] = values
                }
            }
        }
        try await ImageIOKit.write(image, to: output, format: format, quality: 0.97, metadata: props)
    }

    private static func setImageField(_ field: TagEntry, in metadata: CGMutableImageMetadata) {
        let parts = field.id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, field.removable, field.removed || field.editable else { return }
        let prefixes: [String]
        switch parts[0] {
        case "tiff": prefixes = ["tiff"]
        case "exif", "exifaux": prefixes = ["exif", "exifEX", "aux"]
        case "iptc": prefixes = ["Iptc4xmpCore", "photoshop", "dc"]
        default: return     // GPS is excluded as a whole through the destination options.
        }
        let value = field.value.trimmingCharacters(in: .whitespaces)
        for prefix in prefixes {
            let path = "\(prefix):\(parts[1])" as CFString
            if field.removed || value.isEmpty { CGImageMetadataRemoveTagWithPath(metadata, nil, path) }
            else if CGImageMetadataCopyTagWithPath(metadata, nil, path) != nil || prefix == prefixes[0] {
                CGImageMetadataSetValueWithPath(metadata, nil, path, value as CFString); return
            }
        }
    }

    private static func writePDF(_ source: URL, to output: URL, fields: [TagEntry], removeAll: Bool) throws {
        let document = try PDFConverter.open(source)
        var attributes: [AnyHashable: Any] = removeAll ? [:] : (document.documentAttributes ?? [:])
        if !removeAll {
            for field in fields where field.id.hasPrefix("pdf.") && (field.removed || field.editable) {
                let key = PDFDocumentAttribute(rawValue: String(field.id.dropFirst(4)))
                if field.removed || field.value.isEmpty { attributes.removeValue(forKey: key) }
                else if key == .keywordsAttribute { attributes[key] = field.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                else { attributes[key] = field.value }
            }
        } else {
            attributes = [PDFDocumentAttribute.producerAttribute: "", PDFDocumentAttribute.creatorAttribute: ""]
        }
        document.documentAttributes = attributes
        guard document.write(to: output) else { throw LimeError("Lime couldn't save the PDF without its tags.") }
    }
}
