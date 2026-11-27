// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Observation

enum UpdateState: Equatable {
    /// Nothing known yet this session.
    case idle
    case checking
    case upToDate
    /// A newer version is published; nothing downloaded.
    case available
    case downloading
    /// The new version is downloaded and verified, waiting to be installed.
    case ready
    case installing
    case failed
}

/// App updates: the "Updates" section of the Settings page, and the automatic check behind
/// it (TVControlForWin's UpdateViewModel).
///
/// With both settings on, a new version is found within a day of being published,
/// downloaded in the background, and installed the next moment the window isn't open. The
/// app is away for the few seconds the swap takes and comes back in the menu bar. A copy
/// that can't replace itself where it is only points to the download page.
@MainActor
@Observable
final class UpdateManager {
    private static let checkEvery: TimeInterval = 24 * 60 * 60
    private static let firstCheckDelay: TimeInterval = 30
    private static let timerInterval: TimeInterval = 60 * 60
    // How long the app may take to quit for an update before the attempt counts as failed.
    // The helper gives up a little sooner (after a minute) and leaves everything as it was.
    private static let quitGrace: TimeInterval = 75

    /// How this copy is installed, which decides what an update can do by itself.
    let kind: InstallKind
    /// Why it's that kind, for the info text.
    let kindReason: InstallKindReason

    // MARK: What the Settings section shows

    private(set) var state: UpdateState = .idle
    /// Download progress, in percent.
    private(set) var progress = 0
    /// Mirrors of the two settings, kept here so the switches redraw on their own.
    private(set) var checkAutomatically: Bool
    private(set) var installAutomatically: Bool

    @ObservationIgnored private let readSettings: () -> AppSettings
    @ObservationIgnored private let modifySettings: (_ change: (inout AppSettings) -> Void) -> Void
    @ObservationIgnored private let isMainWindowOpen: () -> Bool
    @ObservationIgnored private let quitForUpdate: () -> Void

    @ObservationIgnored private let service: UpdateService
    @ObservationIgnored private let helperFailStep: String?
    // Automatic checks are off for trial runs on their own data folder, unless they name a
    // stand-in feed to rehearse against.
    @ObservationIgnored private let automatic: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var update: AppUpdate?
    @ObservationIgnored private var archive: URL?
    @ObservationIgnored private var failure = ""

    /// - Parameters:
    ///   - settings: Returns the current settings (`AppState.shared.settings`). Read each time
    ///     a decision is made, never cached.
    ///   - modifySettings: Applies a change to the settings and saves them to disk, e.g.
    ///     `{ change in change(&AppState.shared.settings); AppState.shared.saveSettings() }`.
    ///     Used for the two switches, `lastUpdateCheckUtc` and `unattendedInstallTried`.
    ///   - isMainWindowOpen: True while the main window is on screen (visible, including
    ///     behind other windows; minimized counts as open). An update never restarts the app
    ///     under someone who has its window open.
    ///   - quitForUpdate: Quits the app normally and promptly (`NSApp.terminate(nil)`), with
    ///     the usual shutdown path. Called right after the swap helper has started; the helper
    ///     waits for this process to exit before touching the bundle.
    init(settings: @escaping () -> AppSettings,
         modifySettings: @escaping (_ change: (inout AppSettings) -> Void) -> Void,
         isMainWindowOpen: @escaping () -> Bool,
         quitForUpdate: @escaping () -> Void) {
        readSettings = settings
        self.modifySettings = modifySettings
        self.isMainWindowOpen = isMainWindowOpen
        self.quitForUpdate = quitForUpdate

        let setup = UpdateService.forThisCopy()
        service = setup.service
        kind = setup.kind
        kindReason = setup.reason
        helperFailStep = setup.helperFailStep
        automatic = setup.kind != .none && (setup.isRehearsal || !AppPaths.isTrialRun)

        let current = settings()
        checkAutomatically = current.checkForUpdates
        installAutomatically = current.installUpdatesAutomatically
    }

    /// Begins the daily automatic check. The first one waits until startup has settled.
    func start() {
        guard kind != .none else { return }
        let settings = readSettings()
        Log.write("update: this copy is \(kind.rawValue) (\(kindReason.rawValue))\(service.feed.absoluteString == AppInfo.latestReleaseApi ? "" : ", feed \(service.feed.absoluteString)")")

        // Windows never compares at startup: a failed unattended install shows only in that
        // the old version is still running while `unattendedInstallTried` names a newer one,
        // and the check in `installIfUnattended` keeps it from trying again. Logged here so
        // the outcome is visible.
        if AppInfo.launchedAfterUpdate {
            if let tried = settings.unattendedInstallTried,
               AppInfo.compareVersions(tried, AppInfo.version) == .orderedDescending {
                Log.write("update: back on \(AppInfo.version); installing \(tried) didn't work, so it waits for Install")
            } else {
                Log.write("update: running \(AppInfo.version) after an update")
            }
        }

        service.deleteUsedDownloads()
        guard automatic else { return }
        scheduleTimer(after: Self.firstCheckDelay)
    }

    /// Stops the timer and any check or download in progress. Call on shutdown.
    func dispose() {
        timer?.invalidate()
        timer = nil
        work?.cancel()
        work = nil
    }

    /// The settings were replaced wholesale (a backup was imported): re-read the switches.
    func settingsReloaded() {
        let settings = readSettings()
        checkAutomatically = settings.checkForUpdates
        installAutomatically = settings.installUpdatesAutomatically
    }

    private func scheduleTimer(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleTimer(after: Self.timerInterval) // the first tick comes sooner
                if self.isCheckDue { self.run { await $0.check(manual: false) } }
            }
        }
        timer.tolerance = min(delay / 10, 60)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var isCheckDue: Bool {
        let settings = readSettings()
        guard settings.checkForUpdates else { return false }
        guard let last = settings.lastUpdateCheckUtc else { return true }
        let since = Date().timeIntervalSince(last)
        return since >= Self.checkEvery || since < 0 // the clock went backwards: don't wait it out
    }

    // MARK: Derived state

    var versionLabel: String { "Version \(AppInfo.version)" }

    private var newVersion: String { update?.version ?? "" }

    var statusText: String {
        switch state {
        case .checking: return "Checking"
        case .upToDate: return "Up to date"
        case .available: return "\(newVersion) is available"
        case .downloading: return "Downloading \(newVersion), \(progress)%"
        case .ready: return "\(newVersion) is ready to install"
        case .installing: return "Installing \(newVersion)"
        case .failed: return failure
        case .idle: return ""
        }
    }

    // A copy that can't replace itself, or a release without a zip this app can verify, is
    // updated by hand: the button opens the download page.
    private var byHand: Bool { kind != .selfUpdating || update?.asset == nil }

    var buttonText: String {
        switch state {
        case .available: return byHand ? "Download" : "Update"
        case .ready: return "Install"
        default: return "Check now"
        }
    }

    var isBusy: Bool { state == .checking || state == .downloading || state == .installing }

    var buttonEnabled: Bool { !isBusy }

    /// A newer version is waiting on the user: drives the dot on the Settings tab.
    var hasUpdate: Bool { state == .available || state == .ready }

    /// Whether the Settings section offers the update switches at all.
    var offersUpdates: Bool { kind != .none }

    /// "Install automatically" only means something for a copy that can replace itself.
    var offersAutomaticInstall: Bool { kind == .selfUpdating }

    /// Why updates are installed by hand for this copy, when they are; nil otherwise.
    var manualReasonText: String? {
        guard kind == .manual else { return nil }
        switch kindReason {
        case .translocated:
            return "macOS is running this copy from a temporary place, so it can't update itself. Move TVControlForMac to your Applications folder and open it from there."
        case .readOnlyVolume:
            return "This copy is running from the disk image, so it can't update itself. Drag TVControlForMac to your Applications folder and open it from there."
        case .notWritable:
            return "Your account can't change the folder this copy is in, so new versions are installed by hand from the download page."
        default:
            return "New versions are installed by hand from the download page."
        }
    }

    // MARK: Switches

    func setCheckAutomatically(_ value: Bool) {
        guard value != readSettings().checkForUpdates else { return }
        modifySettings { $0.checkForUpdates = value }
        checkAutomatically = value
        if value && automatic && isCheckDue { run { await $0.check(manual: false) } }
    }

    func setInstallAutomatically(_ value: Bool) {
        guard value != readSettings().installUpdatesAutomatically else { return }
        modifySettings { $0.installUpdatesAutomatically = value }
        installAutomatically = value
    }

    // MARK: Actions

    /// The section's one button: check, update, download or install, by what's known so far.
    func buttonPressed() {
        switch state {
        case .available where byHand:
            openDownloadPage()
        case .available:
            run { manager in
                if await manager.download() { await manager.install(quiet: false) }
            }
        case .ready:
            install()
        default:
            checkNow()
        }
    }

    /// Asks now whether a newer version is published, as the button does.
    func checkNow() {
        run { await $0.check(manual: true) }
    }

    /// Installs the downloaded update now, with the window open: the app restarts with it.
    func install() {
        run { await $0.install(quiet: false) }
    }

    /// Opens the release's page (or the releases page) in the browser.
    func openDownloadPage() {
        // Always a GitHub web address: UpdateService.parse makes sure of it.
        let page = update?.pageURL ?? URL(string: AppInfo.releasesPage)!
        if !NSWorkspace.shared.open(page) {
            Log.write("update: couldn't open the download page")
        }
    }

    /// The window was closed to the menu bar: a downloaded update can go in now.
    func windowClosed() {
        run { await $0.installIfUnattended() }
    }

    // One piece of work at a time; the button is disabled while one runs.
    private func run(_ body: @escaping @MainActor (UpdateManager) async -> Void) {
        guard kind != .none, work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.work = nil
        }
    }

    /// Asks whether a newer version is published. An automatic check that finds one carries
    /// on to download it, and to install it if that can be done unattended; a failed
    /// automatic check stays quiet and is tried again an hour later.
    private func check(manual: Bool) async {
        if isBusy || (state == .ready && !manual) { return }

        let before = state
        state = .checking
        let latest: AppUpdate?
        do {
            latest = try await service.latest()
        } catch {
            if Task.isCancelled { return }
            Log.write("update: check failed (\(error.localizedDescription))")
            if manual {
                failure = "Couldn't check. Try again later"
                state = .failed
            } else {
                // Nothing to tell anyone: put back what was showing.
                state = before == .checking || before == .failed ? .idle : before
            }
            return
        }
        modifySettings { $0.lastUpdateCheckUtc = Date() }

        guard let latest, AppInfo.compareVersions(latest.version, AppInfo.version) == .orderedDescending else {
            update = nil
            archive = nil
            state = .upToDate
            return
        }

        if latest.version != update?.version { archive = nil }
        update = latest
        Log.write("update: \(latest.version) is available\(latest.asset == nil ? " (by hand: \(latest.assetProblem ?? "no file"))" : "")")

        // A verified download from earlier (say, before a restart) is still good.
        if archive == nil, let asset = latest.asset, kind == .selfUpdating {
            let file = service.downloadDir.appendingPathComponent(asset.name)
            if UpdateService.matches(file, asset) { archive = file }
        }
        state = archive == nil ? .available : .ready

        let settings = readSettings()
        if !byHand && settings.installUpdatesAutomatically && settings.checkForUpdates {
            if archive != nil {
                await installIfUnattended()
            } else if await download() {
                await installIfUnattended()
            }
        }
    }

    /// Downloads the release's zip, checks its size and hash, and test-unpacks it so the app
    /// inside is checked before it's offered for installing.
    private func download() async -> Bool {
        guard let update, let asset = update.asset else { return false }

        progress = 0
        state = .downloading
        do {
            let service = self.service
            let file = try await service.download(update) { [weak self] fraction in
                let percent = Int(min(max(fraction * 100, 0), 100))
                Task { @MainActor in
                    guard let self, self.state == .downloading, percent != self.progress else { return }
                    self.progress = percent
                }
            }
            let app = Bundle.main.bundleURL
            try await Task.detached {
                let staged = try UpdateService.stage(archive: file, version: asset.version, nextTo: app)
                try? FileManager.default.removeItem(at: staged.root)
            }.value
            archive = file
            state = .ready
            Log.write("update: \(update.version) downloaded and verified")
            return true
        } catch {
            if Task.isCancelled { return false }
            Log.write("update: download failed (\(error.localizedDescription))")
            archive = nil
            try? FileManager.default.removeItem(at: service.downloadDir.appendingPathComponent(asset.name))
            failure = "Download failed. Try again later"
            state = .failed
            return false
        }
    }

    // Unattended means: the user asked for automatic installs, this copy can replace itself,
    // and nobody has the window open.
    private func installIfUnattended() async {
        guard state == .ready, kind == .selfUpdating else { return }
        let settings = readSettings()
        guard settings.installUpdatesAutomatically, settings.checkForUpdates else { return }
        guard !isMainWindowOpen() else { return }

        // One unattended try per version. If the swap fails, the old version comes back and
        // would otherwise restart itself into the same failure every day; from then on this
        // version waits for the Install button.
        guard settings.unattendedInstallTried != newVersion else { return }
        modifySettings { $0.unattendedInstallTried = self.newVersion }

        await install(quiet: true)
    }

    private func install(quiet: Bool) async {
        guard let update, let asset = update.asset, let archive, kind == .selfUpdating,
              UpdateService.matches(archive, asset) else {
            self.archive = nil
            failure = "Download failed. Try again later"
            state = .failed
            return
        }

        Log.write("update: installing \(update.version)\(quiet ? " in the background" : "")")
        state = .installing
        let app = Bundle.main.bundleURL
        let staged: StagedUpdate
        do {
            staged = try await Task.detached {
                try UpdateService.stage(archive: archive, version: asset.version, nextTo: app)
            }.value
        } catch {
            Log.write("update: \(update.version) didn't pass its checks (\(error.localizedDescription))")
            self.archive = nil
            try? FileManager.default.removeItem(at: archive)
            failure = "The update didn't pass its checks"
            state = .failed
            return
        }

        // Staging takes a moment; someone may have opened the window meanwhile.
        if quiet && isMainWindowOpen() {
            try? FileManager.default.removeItem(at: staged.root)
            state = .ready
            return
        }

        do {
            let pid = try UpdateService.launchSwap(staged, replacing: app, quiet: quiet, failStep: helperFailStep)
            Log.write("update: helper \(pid) will swap in \(update.version) once the app has quit")
        } catch {
            Log.write("update: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: staged.root)
            failure = "Couldn't start the update"
            state = .failed
            return
        }

        quitForUpdate()

        // Normally the app is gone long before this. If quitting was refused, the helper has
        // given up and removed the staged copy; the download is still there to try again.
        try? await Task.sleep(nanoseconds: UInt64(Self.quitGrace * 1_000_000_000))
        if state == .installing {
            Log.write("update: the app didn't quit, so \(update.version) wasn't installed")
            failure = "Couldn't restart to update. Try again later"
            state = .failed
        }
    }
}
