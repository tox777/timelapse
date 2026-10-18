// Timelapse: menu bar app that captures the main display once per second
// and writes the frames straight into a 30 fps MP4 in ~/Movies.
import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let startItem = NSMenuItem(title: "Start", action: #selector(startClicked), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: #selector(stopClicked), keyEquivalent: "")
    private let infoItem = NSMenuItem(title: "Listo", action: nil, keyEquivalent: "")

    private enum State { case idle, starting, recording, stopping }
    private var state = State.idle

    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private var startDate = Date()

    private var displayID: CGDirectDisplayID = 0
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var written: Int64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        startItem.target = self
        stopItem.target = self
        infoItem.isEnabled = false
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(infoItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateUI()
    }

    // MARK: - Menu actions

    @objc private func startClicked() {
        guard state == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Only shows the system prompt the first time; after a denial it just returns false.
            CGRequestScreenCaptureAccess()
            showPermissionAlert()
            return
        }
        state = .starting
        updateUI()
        Task { await beginRecording() }
    }

    @objc private func stopClicked() {
        Task { await stopRecording() }
    }

    @objc private func quitClicked() {
        Task {
            await stopRecording()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Recording

    private func beginRecording() async {
        do {
            let content = try await SCShareableContent.current
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                throw TimelapseError("No se encontró la pantalla principal.")
            }

            // Output size in points (not Retina pixels), capped at 1920 wide, even dimensions for H.264.
            var width = display.width
            var height = display.height
            if width > 1920 {
                height = height * 1920 / width
                width = 1920
            }
            width -= width % 2
            height -= height % 2

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true

            let url = Self.makeOutputURL()
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? TimelapseError("No se pudo crear el video.")
            }
            writer.startSession(atSourceTime: .zero)

            self.displayID = display.displayID
            self.filter = SCContentFilter(display: display, excludingWindows: [])
            self.config = config
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.outputURL = url
            self.written = 0
            self.startDate = Date()
            self.state = .recording

            // .common mode keeps the timer firing while the status menu is open.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        } catch {
            resetRecordingState()
            showAlert("No se pudo iniciar la grabación", error.localizedDescription)
        }
        updateUI()
    }

    private func tick() {
        guard state == .recording else { return }
        updateInfo()
        // Skip this tick if the previous capture hasn't come back yet.
        guard captureTask == nil, let filter, let config else { return }
        captureTask = Task { [weak self] in
            let sample = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            self?.handle(sample)
            self?.captureTask = nil
        }
    }

    private func handle(_ sample: CMSampleBuffer?) {
        guard state == .recording, let input, let adaptor else { return }
        guard let sample, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            // Screen locked or asleep: skip the frame. If the display itself is gone, stop and keep what we have.
            if CGDisplayIsOnline(displayID) == 0 {
                Task {
                    await stopRecording()
                    showAlert("Grabación detenida", "La pantalla que se estaba grabando se desconectó. El video se guardó con lo grabado.")
                }
            }
            return
        }
        guard input.isReadyForMoreMediaData else { return }
        // Count only frames actually written so the video has no gaps.
        if adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: written, timescale: 30)) {
            written += 1
        }
    }

    private func stopRecording() async {
        guard state == .recording, let writer, let input, let outputURL else { return }
        state = .stopping
        updateUI()
        timer?.invalidate()
        timer = nil
        if let inFlight = captureTask {
            await inFlight.value
        }

        input.markAsFinished()
        if written == 0 {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        } else {
            await writer.finishWriting()
            if writer.status == .completed {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } else {
                showAlert("No se pudo guardar el video", writer.error?.localizedDescription ?? "Error desconocido.")
            }
        }
        resetRecordingState()
        updateUI()
    }

    private func resetRecordingState() {
        state = .idle
        filter = nil
        config = nil
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        captureTask = nil
    }

    // MARK: - UI

    private func updateUI() {
        let recording = state == .recording
        startItem.isEnabled = state == .idle
        stopItem.isEnabled = recording
        if let button = statusItem.button {
            let symbol = recording ? "record.circle.fill" : "record.circle"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Timelapse")
            button.contentTintColor = recording ? .systemRed : nil
        }
        switch state {
        case .idle: infoItem.title = "Listo"
        case .starting: infoItem.title = "Iniciando…"
        case .recording: updateInfo()
        case .stopping: infoItem.title = "Guardando video…"
        }
    }

    private func updateInfo() {
        let elapsed = Int(Date().timeIntervalSince(startDate))
        let clock = String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
        infoItem.title = "\(clock) · \(written) frames"
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Timelapse necesita permiso de Grabación de pantalla"
        alert.informativeText = "Activa Timelapse en Ajustes > Privacidad y seguridad > Grabación de pantalla, luego sal y vuelve a abrir Timelapse."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Timelapse-\(formatter.string(from: Date())).mp4")
    }
}

struct TimelapseError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
