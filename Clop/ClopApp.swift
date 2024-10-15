//
//  ClopApp.swift
//  Clop
//
//  Created by Alin Panaitiu on 16.07.2022.
//

import SwiftUI

import Cocoa
import Combine
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import Sentry
import ServiceManagement
import System
import UniformTypeIdentifiers
#if SETAPP
    import LowtechSetapp
    import Setapp
#else
    import LowtechIndie
    import LowtechPro
#endif

var pauseForNextClipboardEvent = false

class WindowManager: ObservableObject {
    @Published var windowToOpen: String? = nil

    func open(_ window: String) {
        windowToOpen = window
    }
}
let WM = WindowManager()

extension NSPasteboard {
    func debug() {
        #if DEBUG
            print(name.rawValue)
            guard let pasteboardItems else {
                print("No items")
                return
            }
            for item in pasteboardItems {
                item.types.filter { ![NSPasteboard.PasteboardType.rtf, NSPasteboard.PasteboardType(rawValue: "public.utf16-external-plain-text")].contains($0) }.forEach { type in
                    print(type.rawValue + " " + (item.string(forType: type) ?! String(describing: item.propertyList(forType: type) ?? item.data(forType: type) ?? "<EMPTY DATA>")))
                }
            }
        #endif
    }
}

#if SETAPP
    typealias AppDelegateParent = LowtechAppDelegate
    struct Pro {
        let active = true
    }
#else
    typealias AppDelegateParent = LowtechProAppDelegate
#endif

enum OptimisationSource: Codable, Equatable, Hashable {
    case clipboard
    case service
    case photos
    case openWith
    case fileWatcher
    case shortcuts
    case cli
    case dropZone
    case finder
    case dir(String)

    var string: String {
        switch self {
        case .clipboard: "clipboard"
        case .service: "service"
        case .photos: "photos"
        case .openWith: "openWith"
        case .fileWatcher: "fileWatcher"
        case .shortcuts: "shortcuts"
        case .cli: "cli"
        case .dropZone: "dropZone"
        case .finder: "finder"
        case let .dir(dir): dir
        }
    }
}

extension String {
    var optSource: OptimisationSource? {
        switch self {
        case "clipboard": .clipboard
        case "service": .service
        case "photos": .photos
        case "shortcuts": .shortcuts
        case "cli": .cli
        case "finder": .finder
        case "openWith", "open-with", "open with": .openWith
        case "fileWatcher", "file-watcher", "file watcher": .fileWatcher
        case "dropZone", "drop-zone", "drop zone": .dropZone
        default: .dir(self)
        }
    }
}

class AppDelegate: AppDelegateParent {
    var didBecomeActiveAtLeastOnce = false

    var videoWatcher: FileOptimisationWatcher?
    var imageWatcher: FileOptimisationWatcher?
    var pdfWatcher: FileOptimisationWatcher?

    @MainActor var swipeEnded = true

    @Setting(.floatingResultsCorner) var floatingResultsCorner
    lazy var draggingSet: PassthroughSubject<Bool, Never> = debouncer(in: &observers, every: .milliseconds(200)) { dragging in
        mainActor {
            DM.dragging = dragging
            if !dragging {
                DM.dropped = true
            } else {
                showFloatingThumbnails(force: true)
            }
        }
    }

    var lastDragChangeCount = NSPasteboard(name: .drag).changeCount

    #if SETAPP
        let pro = Pro()
    #endif

    @MainActor lazy var dragMonitor = GlobalEventMonitor(mask: [.leftMouseDragged]) { event in
        guard self.finishedOnboarding, NSEvent.pressedMouseButtons > 0, proactive || DM.optimisationCount <= 5 else {
            return
        }

        let drag = NSPasteboard(name: .drag)
//        drag.debug()
        guard self.lastDragChangeCount != drag.changeCount else {
            return
        }
        DM.dropped = false
        self.lastDragChangeCount = drag.changeCount

        guard let items = drag.pasteboardItems, !items.contains(where: { $0.types.set.hasElements(from: [.promise, .promisedFileName, .promisedFileURL, .promisedSuggestedFileName, .promisedMetadata]) }) else {
            DM.itemsToOptimise = []
            self.draggingSet.send(true)
            return
        }

        dropZoneKeyGlobalMonitor.start()
        dropZoneKeyLocalMonitor.start()

        let toOptimise: [ClipboardType] = items.compactMap { item -> ClipboardType? in
            let types = item.types
            if types.contains(.fileURL), let url = item.string(forType: .fileURL)?.url,
               let path = url.existingFilePath, path.isImage || path.isVideo || path.isPDF
            {
                return .file(path)
            }

            if let str = item.string(forType: .string), let path = str.existingFilePath, path.isImage || path.isVideo || path.isPDF {
                return .file(path)
            }

            if types.contains(.URL), let url = item.string(forType: .URL)?.url ?? item.string(forType: .string)?.url, url.isImage || url.isVideo || url.isPDF {
                return .url(url)
            }

            if types.set.hasElements(from: IMAGE_VIDEO_PASTEBOARD_TYPES) || types.contains(.pdf) {
                return .file(FilePath.tmp)
            }

            if let str = item.string(forType: .string), let url = str.url, url.isImage || url.isVideo || url.isPDF {
                return .url(url)
            }

            return nil
        }

        guard toOptimise.isNotEmpty else {
            DM.itemsToOptimise = []
            return
        }

        DM.itemsToOptimise = toOptimise
        self.draggingSet.send(true)
    }

    @MainActor lazy var mouseUpMonitor = GlobalEventMonitor(mask: [.leftMouseUp]) { event in
        self.draggingSet.send(false)
        if !DM.dragHovering, DM.itemsToOptimise.isNotEmpty {
            DM.dragging = false
            DM.itemsToOptimise = []
        }
    }

    @Setting(.optimiseVideoClipboard) var optimiseVideoClipboard

    var machPortThread: Thread?
    var machPortStopThread: Thread?

    var finishedOnboarding = Defaults[.launchCount] > 0

    lazy var onboardingWindowController: NSWindowController? = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
        window.title = "Onboarding"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.closable, .resizable, .titled]
        window.center()
        let wc = NSWindowController(window: window)
        window.windowController = wc

        return wc
    }()

    var sentryCrashExceptionApplicationType: AnyClass?

    var fileCleaner: Timer?

    @MainActor
    static func handleStopOptimisationRequest(_ req: StopOptimisationRequest) {
        log.debug("Stopping optimisation request: \(req.jsonString)")

        for id in req.ids {
            guard let opt = opt(id) else {
                continue
            }

            opt.stop(remove: req.remove)
            opt.uiStop()
        }
    }

    static func handleOptimisationRequest(_ req: OptimisationRequest) -> Data? {
        log.debug("Handling optimisation request: \(req.jsonString)")

        let sem = DispatchSemaphore(value: 0)
        var resp: [OptimisationResponse] = []
        tryAsync {
            resp = try await processOptimisationRequest(req)
            sem.signal()
        }
        sem.wait()

        return resp.jsonData
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task.init {
            await handleURLs(application, urls)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Task.init {
            await handleURLs(sender, filenames.compactMap(\.url))
        }
    }

    func handleURLs(_ application: NSApplication, _ urls: [URL]) async {
        do {
            try await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
                for item in urls.map(ClipboardType.fromURL(_:)) {
                    let source: OptimisationSource = item.path.string.contains("com.apple.Photos") ? .photos : .openWith
                    let added = group.addTaskUnlessCancelled {
                        try await optimiseItem(
                            item,
                            id: item.id,
                            adaptiveOptimisation: false,
                            optimisationCount: &manualOptimisationCount,
                            copyToClipboard: false,
                            source: source,
                            removeAudio: false,
                            optimisedFileBehaviour: source == .photos ? .inPlace : nil
                        )
                    }
                    guard added else { break }
                    try await group.next()
                }
            }
        } catch {
            log.error("Error optimising files from 'Open with': \(error.localizedDescription)")
            await application.reply(toOpenOrPrint: .failure)
        }
        await application.reply(toOpenOrPrint: .success)
    }

    func setupServiceProvider() {
        NSApp.registerServicesMenuSendTypes([.png, .pdf, .fileURL, .fileContents], returnTypes: [.png, .pdf, .fileURL, .fileContents])
        NSApplication.shared.servicesProvider = ContextualMenuServiceProvider()
        NSUpdateDynamicServices()
    }

    @MainActor
    func handleCommandHotkey(_ key: SauceKey) {
        guard finishedOnboarding, let opt = OM.hovered else {
            return
        }

        switch key {
        case .comma:
            WM.open("settings")
            focus()
        case .minus where opt.downscaleFactor > 0.1:
            opt.downscale()
        case .x where opt.changePlaybackSpeedFactor < 10 && opt.canChangePlaybackSpeed():
            opt.changePlaybackSpeed()
        case .delete:
            hoveredOptimiserID = nil
            opt.stop(animateRemoval: true)
        case .space:
            opt.quicklook()
        case .z where !opt.isOriginal:
            opt.restoreOriginal()
        case .r where !opt.running:
            opt.editingFilename = true
        case .d where opt.url != nil && opt.comparisonOriginalURL != nil:
            opt.compare()
        case .c:
            opt.copyToClipboard()
            opt.overlayMessage = "Copied"
        case .s:
            opt.save()
        case .f:
            opt.showInFinder()
        case .u:
            opt.uploadWithDropshare()
        case .o:
            guard let url = opt.url ?? opt.originalURL else { return }
            NSWorkspace.shared.open(url)
        case .a where !opt.aggressive:
            if opt.downscaleFactor < 1 {
                opt.downscale(toFactor: opt.downscaleFactor, aggressiveOptimisation: true)
            } else {
                opt.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
            }
        default:
            return
        }
    }

    @MainActor
    func handleHotkey(_ key: SauceKey) {
        guard finishedOnboarding else { return }

        switch key {
        case .escape:
            OM.clearVisibleOptimisers(stop: true)
        case .minus:
            if let opt = OM.current {
                guard opt.downscaleFactor > 0.1 else { return }
                opt.downscale()
            } else {
                guard scalingFactor > 0.1 else { return }
                scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
                Task.init { try? await optimiseLastClipboardItem(downscaleTo: scalingFactor) }
            }
        case .x:
            if let opt = OM.current, opt.canChangePlaybackSpeed() {
                guard opt.changePlaybackSpeedFactor < 10 else { return }
                opt.changePlaybackSpeed()
            } else {
                Task.init { try? await optimiseLastClipboardItem(changePlaybackSpeedBy: 1.25) }
            }
        case .r:
            if let opt = OM.current, !opt.running {
                opt.editingFilename = true
            }
        case .delete:
            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                hoveredOptimiserID = nil
                opt.stop(animateRemoval: true)
            }
        case .equal:
            if let opt = OM.removedOptimisers.popLast() {
                opt.bringBack()
            }
        case .space:
            if let opt = OM.current, !opt.inRemoval {
                opt.quicklook()
            } else {
                Task.init { try? await quickLookLastClipboardItem() }
            }
        case .z:
            if let opt = OM.current, !opt.inRemoval, !opt.isOriginal {
                opt.restoreOriginal()
            }
        case .p:
            if Defaults[.pauseAutomaticOptimisations] {
                Defaults[.pauseAutomaticOptimisations] = false
                pauseForNextClipboardEvent = false
                showNotice("**Running** • Paused • Stopped\nClop is listening for clipboard and file events")
            } else if pauseForNextClipboardEvent {
                Defaults[.pauseAutomaticOptimisations] = true
                showNotice("Running • Paused • **Stopped**\nAll automatic optimisations are stopped")
            } else {
                pauseForNextClipboardEvent = true
                showNotice("Running • **Paused** • Stopped\nNext clipboard event will be ignored")
            }
        case .c:
            Task.init { try? await optimiseLastClipboardItem() }
        case .a:
            if let opt = OM.current, !opt.inRemoval {
                guard !opt.aggressive else { return }
                if opt.downscaleFactor < 1 {
                    opt.downscale(toFactor: opt.downscaleFactor, aggressiveOptimisation: true)
                } else {
                    opt.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                }
            } else {
                Task.init { try? await optimiseLastClipboardItem(aggressiveOptimisation: true) }
            }
        case SauceKey.NUMBER_KEYS.suffix(from: 1).arr:
            guard let number = key.QWERTYCharacter.d else { break }

            if let opt = OM.current, !opt.inRemoval {
                opt.downscale(toFactor: number / 10.0)
            } else {
                Task.init { try? await optimiseLastClipboardItem(downscaleTo: number / 10.0) }
            }
        default:
            break
        }
    }

    func syncSettings() {
        if Defaults[.syncSettingsCloud] {
            Zephyr.observe(keys: SETTINGS_TO_SYNC)
        }
        pub(.syncSettingsCloud)
            .sink { change in
                if change.newValue {
                    Zephyr.observe(keys: SETTINGS_TO_SYNC)
                } else {
                    Zephyr.stopObserving(keys: SETTINGS_TO_SYNC)
                }
            }.store(in: &observers)
    }
    func initMachPortListener() {
        machPortThread = Thread {
            OPTIMISATION_PORT.listen { data in
                guard let data else {
                    return nil
                }

                var result: Data? = nil
                if let req = OptimisationRequest.from(data) {
                    result = Self.handleOptimisationRequest(req)
                }

                guard let result else {
                    return nil
                }
                return Unmanaged.passRetained(result as CFData)
            }
            RunLoop.current.run()
        }
        machPortStopThread = Thread {
            OPTIMISATION_STOP_PORT.listen { data in
                guard let data, let req = StopOptimisationRequest.from(data) else {
                    return nil
                }

                mainActor { Self.handleStopOptimisationRequest(req) }
                return nil
            }
            RunLoop.current.run()
        }

        machPortThread?.start()
        machPortStopThread?.start()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !SWIFTUI_PREVIEW {
            migrateSettings()
        }
    }

    func createFileCleaner() {
        fileCleaner = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            let interval = Defaults[.workdirCleanupInterval]
            guard interval != .never else {
                return
            }

            for dir in [FilePath.clopBackups, FilePath.videos, FilePath.images, FilePath.pdfs, FilePath.conversions, FilePath.downloads, FilePath.forResize, FilePath.forFilters] {
                let enumerator = fm.enumerator(at: dir.url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                guard let iterator = enumerator else {
                    return
                }

                let now = Date()
                while case let url as URL = iterator.nextObject() {
                    if let isdir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isdir {
                        continue
                    }
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                        continue
                    }

                    if now.timeIntervalSince(date) > interval.rawValue {
                        log.info("Deleting \(url.path) because it's older than \(interval.title) (last modified \(date))")
                        try? fm.removeItem(at: url)
                    }
                }
            }
        }
        fileCleaner?.tolerance = 300
        fileCleaner?.fire()
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        sentryCrashExceptionApplicationType = SentryCrashExceptionApplication.self
        if !SWIFTUI_PREVIEW {
            handleCLIInstall()

            NSApplication.shared.windows.first { $0.title == "Settings" }?.close()
            unarchiveBinaries()
            print(NSFilePromiseReceiver.swizzleReceivePromisedFiles)
            NSView.swizzleDragFormation()
            shouldRestartOnCrash = true

            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .forEach {
                    $0.forceTerminate()
                }
            let _ = shell("/usr/bin/pkill", args: ["-fl", "Clop/bin/(arm64|x86)/.+"], wait: false)
            signal(SIGTERM) { _ in
                for opt in OM.optimisers + OM.removedOptimisers {
                    opt.stop(animateRemoval: false)
                }
                exit(0)
            }
            signal(SIGKILL) { _ in
                for opt in OM.optimisers + OM.removedOptimisers {
                    opt.stop(animateRemoval: false)
                }
                exit(0)
            }

            syncSettings()
            Defaults[.cliInstalled] = fm.fileExists(atPath: CLOP_CLI_BIN_LINK)
            Migrations.run()
            createFileCleaner()
        }

        #if SETAPP
            SetappManager.shared.showReleaseNotesWindowIfNeeded()
        #else
            paddleVendorID = "122873"
            paddleAPIKey = "e1e517a68c1ed1bea2ac968a593ac147"
            paddleProductID = "841006"
            trialDays = 14
            trialText = "This is a trial for the Pro features. After the trial, the app will automatically revert to the free version."
            price = 15
            productName = "Clop Pro"
            vendorName = "THE LOW TECH GUYS SRL"
            hasFreeFeatures = true
        #endif

        if !SWIFTUI_PREVIEW {
            LowtechSentry.sentryDSN = "https://7dad9331a2e1753c3c0c6bc93fb0d523@o84592.ingest.sentry.io/4505673793077248"
            LowtechSentry.configureSentry(getUser: LowtechSentry.getSentryUser)

            KM.primaryKeyModifiers = Defaults[.keyComboModifiers]
            KM.primaryKeys = Defaults[.enabledKeys] + Defaults[.quickResizeKeys]
            KM.onPrimaryHotkey = { key in
                self.handleHotkey(key)
                let _ = checkInternalRequirements(PRODUCTS, nil)
            }

            KM.secondaryKeyModifiers = [.lcmd]
            KM.onSecondaryHotkey = { key in
                self.handleCommandHotkey(key)
                let _ = checkInternalRequirements(PRODUCTS, nil)
            }
        }
        super.applicationDidFinishLaunching(_: notification)
        #if !SETAPP
            UM.updater = updateController.updater
            PM.pro = pro
            if !SWIFTUI_PREVIEW {
                pro.checkProLicense()
            }
        #endif

        Defaults[.videoDirs] = Defaults[.videoDirs].filter { fm.fileExists(atPath: $0) }

        guard !SWIFTUI_PREVIEW else { return }
        floatingResultsWindow.animateOnResize = true
        pub(.workdir)
            .sink {
                FilePath.workdir = FilePath.dir($0.newValue, permissions: 0o777)
            }
            .store(in: &observers)
        pub(.floatingResultsCorner)
            .sink {
                floatingResultsWindow.screenCorner = $0.newValue
                floatingResultsWindow.moveToScreen(.withMouse, corner: $0.newValue)
            }
            .store(in: &observers)
        pub(.keyComboModifiers)
            .sink {
                KM.primaryKeyModifiers = $0.newValue
                KM.reinitHotkeys()
            }
            .store(in: &observers)
        pub(.quickResizeKeys)
            .sink {
                KM.primaryKeys = Defaults[.enabledKeys] + $0.newValue
                KM.reinitHotkeys()
            }
            .store(in: &observers)
        pub(.enabledKeys)
            .sink {
                KM.primaryKeys = $0.newValue + Defaults[.quickResizeKeys]
                KM.reinitHotkeys()
            }
            .store(in: &observers)
        pub(.enableFloatingResults)
            .sink {
                if $0.newValue {
                    showFloatingThumbnails(force: true)
                } else {
                    floatingResultsWindow.close()
                }
            }
            .store(in: &observers)

        if finishedOnboarding {
            initOptimisers()
        } else {
            onboardFileOptimisation()
        }
        trackScrollWheel()

        if Defaults[.enableDragAndDrop] {
            dragMonitor.start()
            mouseUpMonitor.start()
        }
        pub(.enableDragAndDrop)
            .sink { enabled in
                if enabled.newValue {
                    self.dragMonitor.start()
                    self.mouseUpMonitor.start()
                } else {
                    self.dragMonitor.stop()
                    self.mouseUpMonitor.stop()
                }
            }
            .store(in: &observers)
        pub(.enableClipboardOptimiser)
            .sink { enabled in
                if enabled.newValue {
                    self.initClipboardOptimiser()
                } else {
                    clipboardWatcher?.invalidate()
                }
            }
            .store(in: &observers)
        pub(.pauseAutomaticOptimisations)
            .sink { paused in
                if paused.newValue {
                    clipboardWatcher?.invalidate()
                } else {
                    self.initClipboardOptimiser()
                }
            }
            .store(in: &observers)
        initMachPortListener()

        let _ = checkInternalRequirements(PRODUCTS, nil)
        setupServiceProvider()
        startShortcutWatcher()
        Dropshare.fetchAppURL()

        // listen for NSWindow.willCloseNotification to release the window
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMainNotification), name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @MainActor
    func onboardFileOptimisation() {
        print(OnboardingFloatingPreview.om)
        NSApp.setActivationPolicy(.regular)
        onboardingWindowController?.showWindow(self)
        focus()
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window.title == "Settings" || window.title == "Comparison" {
            mainActor {
                settingsViewManager.windowOpen = false
                NSApp.setActivationPolicy(.accessory)
            }
        }

        if window.title == "Onboarding" {
            mainActor {
                self.finishedOnboarding = true
                self.initOptimisers()
                NSApp.setActivationPolicy(.accessory)
                self.onboardingWindowController?.window = nil
                self.onboardingWindowController = nil
            }
        }
    }

    @objc func windowDidBecomeMainNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window.title == "Comparison" {
            NSApp.setActivationPolicy(.regular)
        }

        if window.title == "Settings" {
            mainActor {
                print(FloatingPreview.om, CompactPreview.om)
                settingsViewManager.windowOpen = true
                NSApp.setActivationPolicy(.regular)

                log.debug("Starting settings tab key monitor")
                tabKeyMonitor.start()
            }
        }
    }

    func trackScrollWheel() {
        NSApp.publisher(for: \.currentEvent)
            .filter { event in event?.type == .scrollWheel }
            .throttle(
                for: .milliseconds(20),
                scheduler: DispatchQueue.main,
                latest: true
            )
            .sink { event in
                guard let event else { return }

                mainActor {
                    if self.swipeEnded, !OM.compactResults, self.floatingResultsCorner.isTrailing ? event.scrollingDeltaX > 3 : event.scrollingDeltaX < -3,
                       let hov = hoveredOptimiserID, let optimiser = OM.optimisers.first(where: { $0.id == hov })
                    {
                        hoveredOptimiserID = nil
                        optimiser.stop(remove: true, animateRemoval: true)
                        self.swipeEnded = false
                    }
                    if event.scrollingDeltaX == 0 {
                        self.swipeEnded = true
                    }
                }
            }.store(in: &observers)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if !Defaults[.showMenubarIcon] {
            WM.open("settings")
            focus()
        }

        return true
    }
    override func applicationDidBecomeActive(_ notification: Notification) {
        didBecomeActiveAtLeastOnce = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor func initOptimisers() {
        guard finishedOnboarding else { return }
        let debounceMS = Defaults[.launchCount] == 1 ? 800 : 100

        videoWatcher = FileOptimisationWatcher(
            pathsKey: .videoDirs,
            enabledKey: .enableAutomaticVideoOptimisations,
            maxFilesToHandleKey: .maxVideoFileCount,
            fileType: .video,
            shouldHandle: shouldHandleVideo(event:),
            cancel: cancelVideoOptimisation(path:)
        ) { path in
            guard OM.visibleOptimisers.first(where: { $0.running && $0.id == path.string }) == nil else {
                return
            }
            Task.init {
                let video = Video(path: path)
                let _ = try? await optimiseVideo(video, debounceMS: debounceMS, source: Defaults[.videoDirs].filter { path.string.starts(with: $0) }.max(by: \.count)?.optSource)
            }
        }
        imageWatcher = FileOptimisationWatcher(
            pathsKey: .imageDirs,
            enabledKey: .enableAutomaticImageOptimisations,
            maxFilesToHandleKey: .maxImageFileCount,
            fileType: .image,
            shouldHandle: shouldHandleImage(event:),
            cancel: cancelImageOptimisation(path:)
        ) { path in
            guard OM.visibleOptimisers.first(where: { $0.running && $0.id == path.string }) == nil else {
                return
            }
            Task.init {
                guard let img = Image(path: path, retinaDownscaled: false) else { return }
                let _ = try? await optimiseImage(img, debounceMS: debounceMS, source: Defaults[.imageDirs].filter { path.string.starts(with: $0) }.max(by: \.count)?.optSource)
            }
        }
        pdfWatcher = FileOptimisationWatcher(
            pathsKey: .pdfDirs,
            enabledKey: .enableAutomaticPDFOptimisations,
            maxFilesToHandleKey: .maxPDFFileCount,
            fileType: .pdf,
            shouldHandle: shouldHandlePDF(event:),
            cancel: cancelPDFOptimisation(path:)
        ) { path in
            guard OM.visibleOptimisers.first(where: { $0.running && $0.id == path.string }) == nil else {
                return
            }
            Task.init {
                let _ = try? await optimisePDF(PDF(path), debounceMS: debounceMS, source: Defaults[.pdfDirs].filter { path.string.starts(with: $0) }.max(by: \.count)?.optSource)
            }
        }

        if Defaults[.enableClipboardOptimiser], !Defaults[.pauseAutomaticOptimisations] {
            initClipboardOptimiser()
        }

        let _ = checkInternalRequirements(PRODUCTS, nil)
    }

    @MainActor func initClipboardOptimiser() {
        guard finishedOnboarding else { return }

        clipboardWatcher?.invalidate()
        clipboardWatcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let newChangeCount = NSPasteboard.general.changeCount
            guard newChangeCount != pbChangeCount else {
                return
            }
            pbChangeCount = newChangeCount
            guard !pauseForNextClipboardEvent else {
                pauseForNextClipboardEvent = false
                return
            }
            guard let item = NSPasteboard.general.pasteboardItems?.first, item.string(forType: .optimisationStatus) == nil else {
                return
            }

            mainActor {
                if self.optimiseVideoClipboard, let path = item.existingFilePath, path.isVideo, !path.hasOptimisationStatusXattr() {
                    Task.init {
                        let _ = try? await optimiseVideo(Video(path: path), source: .clipboard)
                        #if SETAPP
                            SetappManager.shared.reportUsageEvent(.userInteraction)
                        #endif
                    }
                    return
                }
                if item.existingFilePath?.isPDF ?? false {
                    return
                }
                #if SETAPP
                    SetappManager.shared.reportUsageEvent(.userInteraction)
                #endif
                optimiseClipboardImage(item: item)
            }
        }

        clipboardWatcher?.tolerance = 100
    }

    #if !SETAPP
        @objc func statusBarButtonClicked(_ sender: NSClickGestureRecognizer) {
            mainActor {
                if OM.skippedBecauseNotPro.isNotEmpty {
                    OM.ignoreProErrorBadge = true
                    sender.isEnabled = false

                    guard let button = sender.view as? NSStatusBarButton else { return }
                    button.performClick(self)
                }
            }
        }
    #endif
}

#if !SETAPP
    var statusItem: NSStatusItem? {
        NSApp.windows.lazy.compactMap { window in
            window.perform(Selector(("statusItem")))?.takeUnretainedValue() as? NSStatusItem
        }.first
    }
#endif

extension NSPasteboardItem {
    var existingFilePath: FilePath? {
        string(forType: .fileURL)?.fileURL?.existingFilePath ?? string(forType: .string)?.fileURL?.existingFilePath
    }
    var filePath: FilePath? {
        string(forType: .fileURL)?.fileURL?.filePath ?? string(forType: .string)?.fileURL?.filePath
    }
    var url: URL? {
        string(forType: .URL)?.url
    }
}

enum ClopFileType: String, CaseIterable, CustomStringConvertible {
    case image
    case video
    case pdf

    var defaultNameTemplatePath: FilePath {
        switch self {
        case .image:
            "~/Desktop/shot.png".filePath!
        case .video:
            "~/Desktop/rec.mp4".filePath!
        case .pdf:
            "~/Desktop/doc.pdf".filePath!
        }
    }

    var optimisedBehaviourKey: Defaults.Key<OptimisedFileBehaviour> {
        switch self {
        case .image:
            .optimisedImageBehaviour
        case .video:
            .optimisedVideoBehaviour
        case .pdf:
            .optimisedPDFBehaviour
        }
    }

    var sameFolderNameTemplateKey: Defaults.Key<String> {
        switch self {
        case .image:
            .sameFolderNameTemplateImage
        case .video:
            .sameFolderNameTemplateVideo
        case .pdf:
            .sameFolderNameTemplatePDF
        }
    }

    var specificFolderNameTemplateKey: Defaults.Key<String> {
        switch self {
        case .image:
            .specificFolderNameTemplateImage
        case .video:
            .specificFolderNameTemplateVideo
        case .pdf:
            .specificFolderNameTemplatePDF
        }
    }

    var optimisedFileBehaviour: OptimisedFileBehaviour {
        Defaults[optimisedBehaviourKey]
    }

    var description: String {
        switch self {
        case .image:
            "image"
        case .video:
            "video"
        case .pdf:
            "PDF"
        }
    }

    var otherCases: [ClopFileType] {
        ClopFileType.allCases.filter { $0 != self }
    }
    var tab: SettingsView.Tabs {
        switch self {
        case .image:
            .images
        case .video:
            .video
        case .pdf:
            .pdf
        }
    }
}

import Ignore

extension EonilFSEventsEvent: Hashable { // @retroactive Hashable {
    public static func == (lhs: EonilFSEventsEvent, rhs: EonilFSEventsEvent) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

@MainActor
class FileOptimisationWatcher {
    init(
        pathsKey: Defaults.Key<[String]>,
        enabledKey: Defaults.Key<Bool>,
        maxFilesToHandleKey: Defaults.Key<Int>,
        fileType: ClopFileType,
        shouldHandle: @escaping (EonilFSEventsEvent) -> Bool,
        cancel: @escaping (FilePath) -> Void,
        handler: @escaping (FilePath) -> Void
    ) {
        self.pathsKey = pathsKey
        self.enabledKey = enabledKey
        self.maxFilesToHandleKey = maxFilesToHandleKey
        self.fileType = fileType
        self.shouldHandle = shouldHandle
        self.cancel = cancel
        self.handler = handler

        pub(pathsKey).sink { [weak self] change in
            self?.paths = change.newValue
            self?.startWatching()
        }.store(in: &observers)

        pub(enabledKey).sink { [weak self] change in
            guard let self else { return }

            enabled = change.newValue
            if change.newValue {
                startWatching()
            } else if watching {
                EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
                watching = false
            }
        }.store(in: &observers)

        pub(maxFilesToHandleKey).sink { [weak self] change in
            self?.maxFilesToHandle = change.newValue
        }.store(in: &observers)

        pub(.pauseAutomaticOptimisations).sink { [weak self] change in
            guard let self else { return }

            if change.newValue {
                if watching {
                    EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
                    watching = false
                }
            } else {
                startWatching()
            }
        }.store(in: &observers)

        startWatching()
    }

    deinit {
        guard watching else { return }
        EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
    }

    var watching = false
    var fileType: ClopFileType

    var pathsKey: Defaults.Key<[String]>
    var enabledKey: Defaults.Key<Bool>
    lazy var paths: [String] = Defaults[pathsKey]
    lazy var enabled: Bool = Defaults[enabledKey]

    var maxFilesToHandleKey: Defaults.Key<Int>
    lazy var maxFilesToHandle: Int = Defaults[maxFilesToHandleKey]

    var handler: (FilePath) -> Void
    var cancel: (FilePath) -> Void
    var shouldHandle: (EonilFSEventsEvent) -> Bool

    var observers = Set<AnyCancellable>()
    var justAddedFiles = Set<EonilFSEventsEvent>()
    var cancelledFiles = Set<FilePath>()
    var alreadyOptimisedFiles = Set<String>()
    var addedFileRemovers = [FilePath: DispatchWorkItem]()
    var alreadyOptimisedFileRemovers = [String: DispatchWorkItem]()

    let startedWatchingAt = Date()

    lazy var delayOptimiserID = "file-watcher-delay-\(fileType.rawValue)"
    var delayOptimiser: Optimiser?

    var addedFilesCleaner: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }
    var addedFilesProcessor: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    var clopIgnoreFileName: String {
        ".clopignore-\(fileType.rawValue)"
    }

    var withinSafeMeasureTime: Bool {
        startedWatchingAt.timeIntervalSinceNow > -30 && Defaults[.launchCount] == 1
    }

    static func waitForModificationDateToSettle(_ path: String) async {
        guard let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date else {
            log.warning("Failed to get modification date of \(path)")
            return
        }

        log.debug("Waiting for modification date of \(path) to settle")
        log.debug("Initial modification date: \(date)")
        var lastDate = date
        while true {
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            } catch {
                log.error("Failed to sleep: \(error)")
                return
            }

            guard let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date else {
                log.warning("Failed to get modification date of \(path)")
                return
            }

            guard date != lastDate else {
                log.debug("Modification date of \(path) settled at \(date)")
                return
            }

            log.debug("Modification date of \(path) is still changing: \(lastDate) -> \(date)")
            lastDate = date
        }
    }

    func isAddedFile(event: EonilFSEventsEvent) -> Bool {
        guard let flag = event.flag, let path = event.path.existingFilePath, let stem = path.stem, !stem.starts(with: ".") else {
            return false
        }

        return flag.isDisjoint(with: [.historyDone, .itemRemoved]) &&
            flag.contains(.itemIsFile) &&
            flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified])
    }

    func stopWatching() {
        if watching {
            LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
            watching = false
        }
    }

    func startWatching() {
        stopWatching()
        guard !paths.isEmpty, enabled, !Defaults[.pauseAutomaticOptimisations] else { return }

        do {
            try LowtechFSEvents.startWatching(paths: paths, for: ObjectIdentifier(self), latency: 0.3) { [weak self] event in
                guard !SWIFTUI_PREVIEW, let self, enabled, isAddedFile(event: event),
                      !self.alreadyOptimisedFiles.contains(event.path),
                      !OM.optimisers.contains(where: { $0.url?.path == event.path }),
                      let path = event.path.existingFilePath, shouldHandle(event)
                else { return }

                let typeName = fileType.description
                addedFilesCleaner = nil
                log.debug("Added \(path.string) to justAddedFiles in the \(typeName) watcher")
                justAddedFiles.insert(event)
                cancelledFiles.remove(path)

                if !withinSafeMeasureTime {
                    addedFileRemovers[path]?.cancel()
                    addedFileRemovers[path] = mainAsyncAfter(ms: 1000) { [weak self] in
                        log.debug("Removed \(path.string) from justAddedFiles in the \(typeName) watcher")
                        self?.justAddedFiles.remove(event)
                        self?.addedFileRemovers.removeValue(forKey: path)
                    }
                }

                Task.init { [weak self] in await self?.checkEventAndProcess(event) }
            }
        } catch {
            log.error("Failed to start watching \(fileType.rawValue) folders: \(error)")
            return
        }
        watching = true
    }

    @MainActor
    func checkEventAndProcess(_ event: EonilFSEventsEvent) async {
        let shouldContinue = await MainActor.run { [weak self] in
            guard let self, enabled else { return false }
            // guard !alreadyOptimisedFiles.contains(event.path) else { return false }
            // guard shouldHandle(event) else { return false }

            if let root = paths.first(where: { event.path.hasPrefix($0) }), let ignorePath = "\(root)/\(clopIgnoreFileName)".existingFilePath, event.path.isIgnored(in: ignorePath.string) {
                log.debug("Ignoring \(event.path) because it's in \(ignorePath.string)")
                return false
            }

            guard !hasSpuriousEvent(event) else { return false }

            guard justAddedFiles.count <= maxFilesToHandle else {
                let notice = "More than \(maxFilesToHandle) \(fileType.rawValue)s appeared in the\n`\(justAddedFiles.first!.path.filePath?.dir.shellString ?? "folder")`, ignoring…"
                log.debug(notice)
                showNotice(notice)
                for path in justAddedFiles.compactMap(\.path.existingFilePath).set.subtracting(cancelledFiles) {
                    log.debug("Cancelling optimisation on \(path)")
                    cancel(path)
                    cancelledFiles.insert(path)
                }
                addedFilesCleaner = mainAsyncAfter(ms: 1000) { [weak self] in
                    log.debug("Cleaning up justAddedFiles and cancelledFiles")
                    self?.cancelledFiles.removeAll()
                    self?.justAddedFiles.removeAll()
                }

                return false
            }

            return true
        }

        guard shouldContinue else { return }
        await Self.waitForModificationDateToSettle(event.path)

        if pauseForNextClipboardEvent {
            log.debug("Skipping \(fileType.description) \(event.path) because Clop was paused")
            pauseForNextClipboardEvent = false
            return
        }

        do {
            try await process(event: event)
        } catch {
            log.error("Failed to process \(fileType.rawValue) \(event.path) file event: \(error)")
        }
    }

    func hasSpuriousEvent(_ event: EonilFSEventsEvent) -> Bool {
        guard withinSafeMeasureTime, !justAddedFiles.isEmpty else {
            return false
        }

        guard justAddedFiles.count <= 5 else {
            log.warning("More than 5 file events on first launch (\(justAddedFiles.count))")

            addedFilesProcessor = nil
            enabled = false
            stopWatching()
            Defaults[enabledKey] = false
            justAddedFiles.removeAll()
            cancelledFiles.removeAll()

            delayOptimiser?.remove(after: 0)
            delayOptimiser = nil

            let alert = NSAlert()
            alert.messageText = "Too many file events"
            alert.informativeText = """
            Clop detected a large number of file change events that happened as soon as Clop started watching the folders.

            This is most likely caused by a third-party app that is constantly modifying files in the folders you selected to automatically optimise.

            To avoid altering files you don't intend to, Clop will stop automatic optimisation in these folders. You can re-enable this feature in the settings.
            """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings")
            alert.alertStyle = .critical
            focus()

            if alert.runModal() == .alertSecondButtonReturn {
                settingsViewManager.tab = fileType.tab
                WM.open("settings")
                focus()
            }

            return true
        }

        delayOptimiser = OM.optimiser(id: delayOptimiserID, type: .unknown, operation: "Initialising file watcher", hidden: false, source: .fileWatcher, indeterminateProgress: true)
        addedFilesProcessor = mainAsyncAfter(ms: 3000) { [weak self] in
            guard let self else { return }
            for event in justAddedFiles.filter({ ev in
                guard let path = ev.path.existingFilePath else { return false }
                return !self.cancelledFiles.contains(path)
            }) {
                Task.init { [weak self] in try await self?.process(event: event) }
            }
            justAddedFiles.removeAll()
            delayOptimiser?.remove(after: 0)
            delayOptimiser = nil
        }

        return true
    }

    @MainActor
    func process(event: EonilFSEventsEvent) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        guard var path = event.path.existingFilePath, !self.cancelledFiles.contains(path) else { return }

        let oldPath = path
        if let newPath = try getTemplatedPath(type: fileType, path: path), newPath != path {
            alreadyOptimisedFiles.insert(newPath.string)
            alreadyOptimisedFiles.insert(path.string)
            path = try path.copy(to: newPath, force: true)
        }

        var count = optimisedCount
        try? await proGuard(count: &count, limit: 5, url: path.url) {
            self.handler(path)
        }
        optimisedCount = count
        alreadyOptimisedFileRemovers[oldPath.string]?.cancel()
        alreadyOptimisedFileRemovers[oldPath.string] = mainAsyncAfter(ms: 3000) { [weak self] in
            self?.alreadyOptimisedFiles.remove(oldPath.string)
            self?.alreadyOptimisedFileRemovers.removeValue(forKey: oldPath.string)
        }
    }

    private var optimisedCount = 0
}

#if !SETAPP
    @MainActor func proLimitsReached(url: URL? = nil) {
        guard !Defaults[.neverShowProError] else {
            if let url, !OM.skippedBecauseNotPro.contains(url) {
                OM.skippedBecauseNotPro = OM.skippedBecauseNotPro.suffix(4).with(url)
            }
            if OM.skippedBecauseNotPro.isNotEmpty {
                let onclick = NSClickGestureRecognizer(target: AppDelegate.instance, action: #selector(AppDelegate.statusBarButtonClicked(_:)))
                statusItem?.button?.addGestureRecognizer(onclick)
            }

            return
        }

        let optimiser = OM.optimiser(id: Optimiser.IDs.pro, type: .unknown, operation: "")
        optimiser.finish(error: "Free version limits reached", notice: "Only 5 file optimisations per session\nare included in the free version", keepFor: 5000)
    }
#else
    @inline(__always) @inlinable
    @MainActor func proLimitsReached(url: URL? = nil) {}
#endif

let floatingResultsWindow = OSDWindow(swiftuiView: FloatingResultContainer().any, level: .floating, canScreenshot: Defaults[.allowClopToAppearInScreenshots], allowsMouse: true)
var clipboardWatcher: Timer?
var pbChangeCount = NSPasteboard.general.changeCount
let THUMB_SIZE = CGSize(width: 300, height: 220)

func migrateSettings() {
    guard let id = Bundle.main.bundleIdentifier else {
        return
    }

    let currentPrefs = URL.libraryDirectory
        .appendingPathComponent("Preferences")
        .appendingPathComponent(id == "com.lowtechguys.Clop-setapp" ? "com.lowtechguys.Clop-setapp.plist" : "com.lowtechguys.Clop.plist")
    let oldPrefs = URL.libraryDirectory
        .appendingPathComponent("Preferences")
        .appendingPathComponent(id == "com.lowtechguys.Clop-setapp" ? "com.lowtechguys.Clop.plist" : "com.lowtechguys.Clop-setapp.plist")

    if !FileManager.default.fileExists(atPath: currentPrefs.path), FileManager.default.fileExists(atPath: oldPrefs.path) {
        try? FileManager.default.copyItem(at: oldPrefs, to: currentPrefs)
        NSUbiquitousKeyValueStore.default.synchronize()
        restart()
    }
}

// MARK: - ClopApp

@main
struct ClopApp: App {
    init() {
        migrateSettings()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase

    @AppStorage("showMenubarIcon") var showMenubarIcon = Defaults[.showMenubarIcon]

    @ObservedObject var om = OM
    @ObservedObject var wm = WM

    #if !SETAPP
        @ObservedObject var pm = PM
    #endif

    var settingsWindow: some Scene {
        let w = Window("Settings", id: "settings") {
            SettingsView()
                .frame(minWidth: 850, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {}
        }

        if #available(macOS 15.0, *) {
            return w
                .windowToolbarLabelStyle(fixed: .titleAndIcon)
        } else {
            return w
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenubarIcon, content: {
            MenuView()
        }, label: {
            #if !SETAPP
                SwiftUI.Image(nsImage: NSImage(resource: !proactive && !om.ignoreProErrorBadge && om.skippedBecauseNotPro.isNotEmpty ? .menubarIconBadge : .menubarIcon))
            #else
                SwiftUI.Image(nsImage: NSImage(resource: .menubarIcon))
            #endif
        })
        .menuBarExtraStyle(.menu)
        .onChange(of: showMenubarIcon) { show in
            if !show {
                openWindow(id: "settings")
                focus()
            } else {
                NSApplication.shared.keyWindow?.close()
            }
        }
        .onChange(of: wm.windowToOpen) { window in
            guard let window else { return }
            openWindow(id: window)
            focus()
            NSApp.keyWindow?.orderFrontRegardless()
            wm.windowToOpen = nil
        }

        settingsWindow
            .handlesExternalEvents(matching: ["openSettings"])

    }
}

@inline(__always) var proactive: Bool {
    #if !SETAPP
        (PRO?.productActivated ?? false) || (PRO?.onTrial ?? false)
    #else
        true
    #endif
}

import ObjectiveC.runtime

extension NSFilePromiseReceiver {
    static let swizzleReceivePromisedFiles: String = {
        let originalSelector = #selector(receivePromisedFiles(atDestination:options:operationQueue:reader:))
        let swizzledSelector = #selector(swizzledReceivePromisedFiles(atDestination:options:operationQueue:reader:))

        guard let originalMethod = class_getInstanceMethod(NSFilePromiseReceiver.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSFilePromiseReceiver.self, swizzledSelector)
        else {
            return "Swizzling NSFilePromiseReceiver.receivePromisedFiles() failed"

        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        return "Swizzled NSFilePromiseReceiver.receivePromisedFiles()"
    }()

    @objc private func swizzledReceivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:], operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        let exc = tryBlock {
            self.swizzledReceivePromisedFiles(atDestination: destinationDir, options: options, operationQueue: operationQueue, reader: reader)
        }
        guard let exc else {
            return
        }
        log.error(exc.description)
    }
}

#if !SETAPP
    import Paddle
#endif

var PRODUCTS: [Any] {
    #if SETAPP
        []
    #else
        if let product {
            [product]
        } else {
            []
        }
    #endif
}

extension NSView {
    static func swizzleDragFormation() {
        guard let NSDragDestination = NSClassFromString("NSDragDestination"),
              let originalMethod = class_getInstanceMethod(NSDragDestination, NSSelectorFromString("_draggingEntered"))
        else {
            return
        }

        let imp = method_getImplementation(originalMethod)

        method_setImplementation(originalMethod, imp_implementationWithBlock({ (self: NSDraggingInfo) in
            self.draggingFormation = .pile
            typealias MyCFunction = @convention(c) (NSDraggingInfo, Selector) -> Void
            let myImp = unsafeBitCast(imp, to: MyCFunction.self)
            return myImp(self, NSSelectorFromString("_draggingEntered"))
        } as @convention(block) (NSDraggingInfo) -> Void))
    }
}

class ContextualMenuServiceProvider: NSObject {
    @objc func stripEXIFService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }
        for item in items.compactMap(\.existingFilePath) {
            stripExifOperationQueue.addOperation {
                item.stripExif()
            }
        }

        stripExifOperationQueue.waitUntilAllOperationsAreFinished()
    }

    @objc func optimisationService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }

        for item in items.map(ClipboardType.fromPasteboardItem) {
            guard item != .unknown else {
                continue
            }
            Task.init {
                try await optimiseItem(
                    item,
                    id: item.id,
                    hideFloatingResult: false,
                    downscaleTo: nil,
                    changePlaybackSpeedBy: nil,
                    aggressiveOptimisation: nil,
                    optimisationCount: &manualOptimisationCount,
                    copyToClipboard: false,
                    source: .service
                )
            }
        }
    }
}
