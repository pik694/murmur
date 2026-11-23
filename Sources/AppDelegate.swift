import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, recording, finishing }
    private enum Finish { case paste, pasteAccurate, copy, cancel }

    private var state = State.idle
    private let recorder = Recorder()
    private let panel = Panel()
    private let downloader = ModelDownloader()
    private var statusItem: NSStatusItem!

    // Loaded models; read from worker threads, assigned on the main thread.
    private var fast: WhisperModel?
    private var accurate: WhisperModel?
    private let loader = DispatchQueue(label: "murmur.loader")

    private var progress: [String: Double] = [:]
    private var downloadError: [String: String] = [:]

    private var startHotKey: UInt32?
    private var sessionHotKeys: [UInt32?] = []
    private var session = 0 // bumps every recording; stale preview results are dropped

    private var shortcut: KeyCombo {
        let index = UserDefaults.standard.integer(forKey: "shortcut")
        return KeyCombo.startChoices.indices.contains(index) ? KeyCombo.startChoices[index] : KeyCombo.startChoices[0]
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_: Notification) {
        // One Murmur at a time: a second copy couldn't register the shortcut anyway
        // (e.g. a login item plus a copy opened from Applications).
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me && !$0.isTerminated }) {
            _exit(0) // see applicationWillTerminate
        }

        WhisperModel.silenceLogs()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        panel.onPaste = { [weak self] in self?.finish(.paste) }
        panel.onCopy = { [weak self] in self?.finish(.copy) }
        panel.onCancel = { [weak self] in self?.finish(.cancel) }

        registerShortcut()
        ensureFastModel()

        if !Paster.canPaste && !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            Paster.requestAccess()
        }
    }

    func applicationWillTerminate(_: Notification) {
        // whisper.cpp 1.8.4's Metal backend aborts in its static destructors at exit
        // (ggml_metal_rsets_free), which made every Quit a crash, and under a
        // KeepAlive launch agent an endless restart. The process is ending anyway, so
        // skip C++ teardown and exit cleanly.
        _exit(0)
    }

    private func registerShortcut() {
        HotKeys.shared.unregister(startHotKey)
        startHotKey = HotKeys.shared.register(shortcut) { [weak self] in self?.toggle() }
        if startHotKey == nil {
            panel.flash("⚠️  \(shortcut.label) is used by another app — pick another shortcut in the menu bar.", seconds: 5)
        }
    }

    // MARK: - Models

    private func ensureFastModel() {
        for spec in [ModelSpec.vad, ModelSpec.fast] where !spec.isInstalled { download(spec) }
        if ModelSpec.fast.isInstalled { loadFast() }
    }

    private func loadFast() {
        loader.async {
            let model = WhisperModel(path: ModelSpec.fast.path.path)
            DispatchQueue.main.async {
                self.fast = model
                self.refreshIcon()
            }
        }
    }

    /// Loads the accurate model if installed; blocks the calling (worker) thread.
    /// Never call from a block already running on `loader` (that would deadlock); use
    /// `loadAccurateOnLoader` there instead.
    private func accurateModel() -> WhisperModel? {
        loader.sync { loadAccurateOnLoader() }
    }

    /// Must run on `loader`.
    private func loadAccurateOnLoader() -> WhisperModel? {
        dispatchPrecondition(condition: .onQueue(loader))
        if accurate == nil, ModelSpec.accurate.isInstalled {
            accurate = WhisperModel(path: ModelSpec.accurate.path.path)
        }
        return accurate
    }

    private func download(_ spec: ModelSpec) {
        downloadError[spec.file] = nil
        progress[spec.file] = 0
        refreshIcon()
        downloader.download(spec, progress: { [weak self] fraction in
            self?.progress[spec.file] = fraction
            self?.refreshIcon()
        }, done: { [weak self] error in
            guard let self else { return }
            self.progress[spec.file] = nil
            if let error {
                self.downloadError[spec.file] = error.localizedDescription
                self.panel.flash("⚠️  Couldn't download \(spec.title)", text: error.localizedDescription, seconds: 5)
            } else if spec.file == ModelSpec.fast.file {
                self.loadFast()
                self.panel.flash("✅  Murmur is ready", text: "Press \(self.shortcut.label) and start talking.", seconds: 4)
            } else if spec.file == ModelSpec.accurate.file {
                self.panel.flash("✅  Accurate model installed", text: "Finish with ⇧⏎ to use it.", seconds: 3)
            }
            self.refreshIcon()
        })
    }

    private var vadPath: String? { ModelSpec.vad.isInstalled ? ModelSpec.vad.path.path : nil }

    // MARK: - Dictation

    private func toggle() {
        switch state {
        case .idle: start()
        case .recording: finish(.paste)
        case .finishing: break
        }
    }

    private func start() {
        guard fast != nil else {
            let pct = progress[ModelSpec.fast.file].map { " (\(Int($0 * 100))%)" } ?? ""
            panel.flash("⏳  The speech model is still downloading\(pct)", seconds: 3)
            if !ModelSpec.fast.isInstalled && !downloader.isDownloading(.fast) { download(.fast) }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.start() } }
            }
            return
        default:
            panel.flash("🎙️  Murmur needs microphone access",
                        text: "System Settings → Privacy & Security → Microphone → turn on Murmur.", seconds: 5)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }

        do {
            try recorder.start()
        } catch {
            panel.flash("⚠️  Couldn't start the microphone", text: error.localizedDescription, seconds: 4)
            return
        }
        state = .recording
        session += 1
        sessionHotKeys = [
            HotKeys.shared.register(.returnKey) { [weak self] in self?.finish(.paste) },
            HotKeys.shared.register(.shiftReturn) { [weak self] in self?.finish(.pasteAccurate) },
            HotKeys.shared.register(.escape) { [weak self] in self?.finish(.cancel) },
        ]
        panel.showRecording(hint: "⏎ paste · ⇧⏎ accurate · ⎋ cancel")
        NSSound(named: "Bottle")?.play()
        refreshIcon()
        runPreview(session: session)
        if ModelSpec.accurate.isInstalled { loader.async { _ = self.loadAccurateOnLoader() } } // warm up for ⇧⏎
    }

    /// Re-transcribes everything recorded so far with the fast model whenever >= 0.25 s of
    /// new audio has arrived, so the panel trails speech by about half a second.
    private func runPreview(session id: Int) {
        guard let model = fast else { return }
        let vad = vadPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done = 0
            while let self, self.isRecording(id) {
                let count = self.recorder.count
                if count < 8_000 || count - done < 4_000 {
                    usleep(50_000)
                    continue
                }
                done = count
                let text = model.transcribe(self.recorder.snapshot(), vadModel: vad)
                DispatchQueue.main.async {
                    if self.state == .recording && self.session == id { self.panel.update(text: text) }
                }
            }
        }
    }

    private func isRecording(_ id: Int) -> Bool {
        DispatchQueue.main.sync { state == .recording && session == id }
    }

    private func finish(_ how: Finish) {
        guard state == .recording else { return }
        state = .finishing
        sessionHotKeys.forEach { HotKeys.shared.unregister($0) }
        sessionHotKeys = []
        let samples = recorder.stop()
        refreshIcon()

        if how == .cancel {
            NSSound(named: "Funk")?.play()
            panel.hide()
            state = .idle
            refreshIcon()
            return
        }

        NSSound(named: "Pop")?.play()
        let wantsAccurate = how == .pasteAccurate
        panel.showBusy(wantsAccurate ? "Transcribing (accurate)…" : "Transcribing…")
        let vad = vadPath
        DispatchQueue.global(qos: .userInitiated).async {
            var model = self.fast
            var note: String?
            if wantsAccurate {
                if let accurate = self.accurateModel() { model = accurate } else { note = "Accurate model not installed — used the fast one." }
            }
            let text = model?.transcribe(samples, vadModel: vad) ?? ""
            DispatchQueue.main.async { self.deliver(text, how: how, note: note) }
        }
    }

    private func deliver(_ text: String, how: Finish, note: String?) {
        defer {
            state = .idle
            refreshIcon()
        }
        guard !text.isEmpty else {
            panel.flash("🤷  Didn't catch anything", seconds: 1.5)
            return
        }
        if how == .copy {
            Paster.copy(text)
            NSSound(named: "Glass")?.play()
            panel.flash("📋  Copied to clipboard", text: text)
        } else if Paster.canPaste {
            panel.hide()
            Paster.paste(text)
            if let note { panel.flash("ℹ️  \(note)", seconds: 2.5) }
        } else {
            Paster.copy(text)
            panel.flash("📋  Copied — press ⌘V to paste",
                        text: "Turn on auto-paste from the Murmur menu bar icon.", seconds: 3)
        }
    }

    // MARK: - Menu bar

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        if state == .recording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
            button.contentTintColor = nil
        }
        if let fraction = progress[ModelSpec.fast.file] {
            button.title = " \(Int(fraction * 100))%"
        } else {
            button.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let label = shortcut.label
        switch state {
        case .idle: menu.addItem(item("Start Dictation (\(label))", #selector(menuToggle), enabled: fast != nil))
        case .recording: menu.addItem(item("Stop & Paste (\(label) or ⏎)", #selector(menuToggle)))
        case .finishing: menu.addItem(item("Transcribing…", nil, enabled: false))
        }
        menu.addItem(.separator())

        menu.addItem(item(modelLine(.fast, ready: fast != nil), nil, enabled: false))
        if let error = downloadError[ModelSpec.fast.file] {
            menu.addItem(item("Retry download (\(error))", #selector(retryFast)))
        }
        if ModelSpec.accurate.isInstalled {
            menu.addItem(item("Accurate model installed — finish with ⇧⏎", nil, enabled: false))
        } else if let fraction = progress[ModelSpec.accurate.file] {
            menu.addItem(item("Downloading accurate model… \(Int(fraction * 100))%", nil, enabled: false))
        } else {
            menu.addItem(item("Download Accurate Model (\(ModelSpec.accurate.sizeLabel))…", #selector(downloadAccurate)))
        }

        if Paster.canPaste {
            menu.addItem(item("Auto-paste: on", nil, enabled: false))
        } else {
            menu.addItem(item("Turn On Auto-paste…", #selector(enableAutoPaste)))
        }

        let shortcuts = NSMenu()
        for (index, combo) in KeyCombo.startChoices.enumerated() {
            let entry = item(combo.label, #selector(pickShortcut(_:)))
            entry.tag = index
            entry.state = combo == shortcut ? .on : .off
            shortcuts.addItem(entry)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit Murmur", #selector(quit)))
    }

    private func modelLine(_ spec: ModelSpec, ready: Bool) -> String {
        if ready { return "Speech model ready" }
        if let fraction = progress[spec.file] { return "Downloading speech model… \(Int(fraction * 100))%" }
        if spec.isInstalled { return "Loading speech model…" }
        return "Speech model not installed"
    }

    private func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        return item
    }

    @objc private func menuToggle() { toggle() }
    @objc private func retryFast() { ensureFastModel() }
    @objc private func downloadAccurate() { download(.accurate) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func enableAutoPaste() {
        Paster.requestAccess()
        Paster.openAccessibilitySettings()
    }

    @objc private func pickShortcut(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "shortcut")
        registerShortcut()
    }
}
