import AppKit

/// Runs chosen wheel operations: conversions, tools (directly or through
/// their options window) and file actions.
@MainActor
final class OperationCoordinator {
    private let settings: AppSettings
    private let progress = JobCardController()
    let shelves: ShelfController
    private var toolWindows: [ToolWindowController] = []
    private var qrWindows: [NSWindow] = []
    /// Number of operations still running; the menu bar shows it.
    private(set) var activeCount = 0 { didSet { onActivityChange?(activeCount) } }
    var onActivityChange: ((Int) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        shelves = ShelfController(settings: settings)
    }

    func perform(_ operation: WheelOperation, files: [URL], at point: NSPoint) {
        let local = files.filter(\.isFileURL)
        guard !local.isEmpty else { return }
        switch operation {
        case .convert(let format):
            run(title: "Converting to \(FormatCatalog.label(format))", count: local.count, at: point) { context in
                try await ConversionEngine.convert(local, to: format, context: context)
            }
        case .tool(let tool):
            if tool == .scanQR { readQR(local, at: point); return }
            if tool == .copyText { copyText(local, at: point); return }
            if tool.hasOptionsWindow { openEditor(tool, files: local, at: point); return }
            runTool(tool, files: local, options: ToolChoices(), at: point)
        case .action(let action):
            FileActions.perform(action, files: local, settings: settings, shelves: shelves, at: point)
        }
    }

    func runTool(_ tool: LimeTool, files: [URL], options: ToolChoices, at point: NSPoint) {
        run(title: Self.progressTitle(tool), count: tool.isAggregate ? 1 : files.count, at: point) { context in
            try await ToolEngine.run(tool, files: files, options: options, context: context)
        }
    }

    private func openEditor(_ tool: LimeTool, files: [URL], at point: NSPoint) {
        let controller = ToolWindowController(tool: tool, files: files, settings: settings) { [weak self] options, origin in
            self?.runTool(tool, files: options.orderedFiles ?? files, options: options, at: origin)
        }
        controller.onClose = { [weak self, weak controller] in self?.toolWindows.removeAll { $0 === controller } }
        toolWindows.append(controller)
        controller.show(near: point)
    }

    private func run(title: String, count: Int, at point: NSPoint, work: @escaping @Sendable (OperationContext) async throws -> [URL]) {
        let model = OperationProgressModel(title: title, total: count)
        let panel = progress.present(model, near: point)
        let output = settings.outputFolder
        let options = settings.optionsProvider
        let task = Task.detached(priority: .userInitiated) {
            do {
                let context = try OperationContext(outputDirectory: output, optionsForFormat: options) { value in
                    Task { @MainActor in
                        model.fraction = value
                        model.saved = min(count - 1, Int(value * Double(count)))
                    }
                }
                let results = try await work(context)
                await MainActor.run {
                    model.outputs = results
                    model.saved = count
                    model.fraction = 1
                    model.phase = .finished
                    NSLog("[Lime] Created: %@", results.map(\.path).joined(separator: ", "))
                }
            } catch is CancellationError {
                await MainActor.run { model.phase = .cancelled }
            } catch {
                await MainActor.run {
                    model.phase = .failed(error.localizedDescription)
                    NSLog("[Lime] Operation failed: %@", error.localizedDescription)
                }
            }
        }
        model.onCancel = { task.cancel() }
        activeCount += 1
        Task { @MainActor [progress] in
            _ = await task.value
            self.activeCount -= 1
            progress.resize(panel)
            switch model.phase {
            case .finished:
                if self.settings.feedback { NSSound(named: "Glass")?.play() }
                progress.close(panel, after: 2.2)
            case .cancelled: progress.close(panel, after: 0.6)
            default: break
            }
        }
    }

    /// Recognizes text off the main thread, copies it and shows the result.
    private func copyText(_ files: [URL], at point: NSPoint) {
        let model = TextResultsModel(files: files)
        let window = TextResultsWindow.make(model: model)
        window.setFrameTopLeftPoint(NSPoint(x: point.x - window.frame.width / 2, y: point.y + 40))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindows.append(window)
        activeCount += 1
        Task.detached(priority: .userInitiated) {
            let results: [TextResultsModel.Entry] = files.map { url in
                do { return .init(url: url, text: try TextRecognition.text(in: url), error: nil) }
                catch { return .init(url: url, text: "", error: error.localizedDescription) }
            }
            await MainActor.run {
                model.finish(results)
                self.activeCount -= 1
                if self.settings.feedback, !model.combined.isEmpty { NSSound(named: "Glass")?.play() }
            }
        }
    }

    private func readQR(_ files: [URL], at point: NSPoint) {
        var results: [(URL, [String])] = []
        for url in files { results.append((url, (try? ImageTools.readQRCodes(url)) ?? [])) }
        let window = QRResultsWindow.make(results: results)
        window.setFrameTopLeftPoint(NSPoint(x: point.x - window.frame.width / 2, y: point.y + 40))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindows.append(window)
    }

    static func progressTitle(_ tool: LimeTool) -> String {
        switch tool {
        case .compress: "Compressing"
        case .stripTags: "Editing metadata"
        case .adjustPhoto: "Editing photo"
        case .markUpPhoto: "Annotating"
        case .addBackdrop: "Adding background"
        case .cropPhoto, .cropClip: "Cropping"
        case .levelAudio: "Normalizing"
        case .silenceVideo: "Muting"
        case .cutVideo, .cutAudio: "Trimming"
        case .splitPages, .sliceVideo: "Splitting"
        case .arrangePages: "Organizing pages"
        case .unpackArchive: "Extracting"
        case .imagesToPDF: "Creating PDF"
        case .combinePDFs: "Merging PDFs"
        case .retimeVideo: "Changing speed"
        case .stitchVideos: "Joining videos"
        case .grabFrames: "Saving frames"
        case .waveVideo: "Visualizing"
        case .remixChannels: "Changing channels"
        case .makeMosaic: "Making collage"
        case .scanQR: "Reading QR"
        case .copyText: "Copying text"
        case .removeBackground: "Removing background"
        case .maskPhoto, .maskVideo: "Redacting"
        case .censorAudio: "Bleeping"
        }
    }
}

/// The six Control-wheel actions.
@MainActor
enum FileActions {
    static func perform(_ action: DropAction, files: [URL], settings: AppSettings, shelves: ShelfController, at point: NSPoint) {
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                alert("AirDrop can't be used right now", "Turn on Wi-Fi and Bluetooth, then try again."); return
            }
            service.perform(withItems: files)
        case .shelf:
            shelves.add(files, at: point)
        case .copy:
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects(files as [NSURL])
        case .pathToClipboard:
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        case .move:
            move(files)
        case .shellHere:
            let first = files[0]
            let isDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let folder = isDirectory ? first : first.deletingLastPathComponent()
            let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.terminal.rawValue) != nil ? settings.terminal.rawValue : ShellApp.terminal.rawValue
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { alert("The terminal app isn’t installed.", ""); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { Task { @MainActor in alert("Couldn’t open the terminal", error.localizedDescription) } }
            }
        }
    }

    static func move(_ files: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = files.count == 1 ? "Where should “\(files[0].lastPathComponent)” go?" : "Where should these \(files.count) items go?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        var moved: [URL] = [], failures: [String] = []
        for file in files {
            if destination.standardizedFileURL.path.hasPrefix(file.standardizedFileURL.path + "/") || destination.standardizedFileURL == file.standardizedFileURL {
                failures.append("“\(file.lastPathComponent)” can’t go inside itself."); continue
            }
            if file.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL { continue }
            let target = OutputPublisher.uniqueURL(directory: destination, stem: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
            do { try fm.moveItem(at: file, to: target); moved.append(target) }
            catch { failures.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { alert(moved.isEmpty ? "Nothing moved." : "The move stopped partway.", failures.joined(separator: "\n")) }
        else if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
