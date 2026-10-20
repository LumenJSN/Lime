import Foundation
import PDFKit

/// PPT/PPTX through the macOS Office Quick Look renderer; images are drawn from its PDF.
enum SlidesConverter {
    static func convert(_ source: URL, to target: String, context: OperationContext) async throws {
        let pdf = target == "pdf" ? context.output(for: source, ext: "pdf") : context.scratch("pdf")
        try await QuickLookExport.slidesPDF(source, to: pdf, workspace: try context.scratchDirectory())
        context.progress(0.5)
        guard target != "pdf" else { return }
        guard let document = PDFDocument(url: pdf), document.pageCount > 0 else { throw LimeError("The new PDF failed its check.") }
        try await DocumentRenderer.exportPages(of: document, source: source, format: target, context: context, dpi: 200)
    }
}

/// ZIP, TAR, GZIP and RAR (read-only) through libarchive's bsdtar.
enum ArchiveTranscoder {
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

    /// Validates members before extraction: no absolute, parent or link entries.
    static func validate(_ archive: URL) async throws {
        let listing = try await ProcessRunner.run(bsdtar, ["-tvf", archive.path])
        let lines = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n")
        guard !lines.isEmpty else { throw LimeError("This archive has nothing in it.") }
        let names = try await ProcessRunner.run(bsdtar, ["-tf", archive.path])
        for (line, name) in zip(lines, String(decoding: names.stdout, as: UTF8.self).split(separator: "\n")) {
            let parts = name.split(separator: "/")
            guard !name.hasPrefix("/"), !parts.contains(".."), let kind = line.first, kind == "-" || kind == "d" || kind == "l" else {
                throw LimeError("Archive contains an unsafe path, link, or special file: \(name)")
            }
        }
    }

    /// Extracts into a staged folder; single gzip files are decompressed.
    static func extract(_ archive: URL, into folder: URL) async throws {
        let lower = archive.lastPathComponent.lowercased()
        if lower.hasSuffix(".gz"), !lower.hasSuffix(".tar.gz") {
            // Plain gzip of one file (bsdtar handles tar.gz and tgz).
            let raw = try? await ProcessRunner.run(bsdtar, ["-tf", archive.path])
            if raw == nil {
                let output = folder.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", "--", archive.path], stdoutTo: output)
                return
            }
        }
        try await validate(archive)
        try await ProcessRunner.run(bsdtar, ["-xf", archive.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"])
        // Links are dropped; bsdtar already refused to write through them.
        let members = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])?.allObjects ?? []
        for case let url as URL in members where (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Archives the members of `items` (files or folders) with relative names.
    static func create(_ items: [URL], format: String, destination: URL, workspace: URL, level: Int = 6) async throws {
        let stage = workspace.appendingPathComponent("archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var names: [String] = []
        for item in items {
            try Task.checkCancellation()
            let target = OutputPublisher.uniqueURL(directory: stage, stem: item.deletingPathExtension().lastPathComponent, ext: item.pathExtension)
            try FileManager.default.copyItem(at: item, to: target)
            names.append(target.lastPathComponent)
        }
        try await createFromFolder(stage, members: names, format: format, destination: destination, level: level)
    }

    static func createFromFolder(_ folder: URL, members: [String]? = nil, format: String, destination: URL, level: Int = 6) async throws {
        let entries = try members ?? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }.sorted()
        guard !entries.isEmpty else { throw LimeError("This archive has nothing in it.") }
        var args: [String]
        switch format {
        case "zip": args = ["--format", "zip", "--options", "zip:compression-level=\(level)", "-cf"]
        case "tar": args = ["--format", "pax", "-cf"]
        case "gz": args = ["--format", "pax", "-z", "--options", "gzip:compression-level=\(max(1, level))", "-cf"]
        default: throw LimeError("Unsupported archive format.")
        }
        args += [destination.path, "-C", folder.path, "--exclude", ".DS_Store", "--"] + entries
        try await ProcessRunner.run(bsdtar, args)
    }

    static func convert(_ source: URL, to target: String, context: OperationContext) async throws {
        let folder = try context.scratchDirectory()
        try await extract(source, into: folder)
        context.progress(0.5)
        let level = context.optionsForFormat(target).compressionLevel
        try await createFromFolder(folder, format: target, destination: context.output(for: source, ext: FormatCatalog.fileExtension(target)), level: level)
    }
}
