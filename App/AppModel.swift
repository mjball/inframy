import AppKit
import InframyKit
import Network
import Observation
import SwiftUI

/// App state. Thin on purpose: the logic lives in InframyKit.
@Observable @MainActor
final class AppModel {
    enum TVState: Equatable {
        case searching(String)
        case connected(TVDeviceInfo, apiVersion: String)
        case unavailable(String)
        /// Not on the TV's network (HomeNetwork): nothing to do until the Mac is back home.
        case away

        var isConnected: Bool { if case .connected = self { return true } else { return false } }
    }

    enum Section: Hashable { case library, tv }

    struct SendJob: Identifiable, Equatable {
        enum Stage: Equatable { case waiting, rendering, uploading, replacing, done(String), failed(String) }
        let id = UUID()
        let photoID: UUID
        let name: String
        var stage: Stage = .waiting

        var isFinished: Bool {
            switch stage { case .done, .failed: return true; default: return false }
        }
    }

    // MARK: State

    var tvState: TVState = .searching("Looking for your Frame…")
    var photos: [LibraryPhoto] = []
    var tvItems: [ContentItem] = []
    var tvThumbnails: [String: NSImage] = [:]
    /// The TV's slideshow. Its interval is the one setting: whatever the TV is using (set from Inframy's
    /// shuffle menu or the TV's remote) is what Inframy uses if it has to turn shuffle back on.
    var slideshow: SlideshowStatus? {
        didSet { if let minutes = slideshow?.intervalMinutes { shuffleMinutes = minutes } }
    }
    /// The image on the TV's screen (`get_current_artwork`), refreshed on every presence check while connected.
    var currentContentID: String?
    /// Art mode on or off, read alongside `currentContentID` (nil until the first read).
    var artModeOn: Bool?
    var jobs: [SendJob] = []
    var section: Section = .library
    /// Photo open in the crop editor.
    var editingPhotoID: UUID?
    var lastError: String?
    var isRefreshingTV = false
    var isSyncingAlbum = false
    /// library.json exists but couldn't be decoded: don't sync or save, so it's never overwritten.
    var libraryUnreadable = false
    /// A sync found many photos gone from the album at once; they wait here until Matt confirms.
    var massRemovalPrompt: MassRemoval?

    struct MassRemoval: Equatable {
        let ids: [UUID]
        let albumTitle: String
    }

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored private let sender: PhotoSender
    @ObservationIgnored private var client: ArtClient?
    @ObservationIgnored private var libraryThumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var isSending = false

    /// Interval Inframy uses when it turns shuffle on: the last one the TV reported.
    var shuffleMinutes: Int {
        get { UserDefaults.standard.object(forKey: Prefs.shuffleMinutes) as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.shuffleMinutes) }
    }

    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isConnecting = false
    /// Consecutive failed REST checks while connected; one miss isn't enough to call the TV asleep.
    @ObservationIgnored private var missedChecks = 0
    /// A Photos change arrived while a sync was running: sync again when it's done.
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var lastShuffleCheck = Date.distantPast
    @ObservationIgnored private var lastDiscoveryAttempt = Date.distantPast
    @ObservationIgnored private var isWaking = false
    @ObservationIgnored private var lastAutoWake = Date.distantPast
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkSettle: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sawFirstPath = false

    init(store: LibraryStore = AppModel.defaultStore()) {
        Prefs.register()
        self.store = store
        self.sender = PhotoSender(store: store)
    }

    /// `INFRAMY_DATA_DIR` points the app at a scratch library (development and screenshots).
    static func defaultStore() -> LibraryStore {
        if let dir = ProcessInfo.processInfo.environment["INFRAMY_DATA_DIR"] {
            return LibraryStore(directory: URL(fileURLWithPath: dir))
        }
        return LibraryStore()
    }

    func start() async {
        // The main window's .task runs again whenever a window opens; start only once.
        guard !started else { return }
        started = true
        let loaded: [LibraryPhoto]
        do {
            loaded = try store.load()
        } catch {
            // Never treat a damaged library as empty: that would re-import everything and save over the crops.
            libraryUnreadable = true
            let backup = store.backUpUnreadableLibrary()
            lastError = "Inframy couldn't read its library (\(error.localizedDescription)). Nothing will be saved or "
                + "synced until it's fixed." + (backup.map { " A copy is at \($0.path)." } ?? "")
            return
        }
        photos = loaded.filter { $0.pendingRemoval != true }
        pendingRemovals = loaded.filter { $0.pendingRemoval == true }
        loadSkipped()
        await migrateAlbumSetting()
        startWatchingAlbum()
        // Development: `INFRAMY_IMPORT=/path/a.jpg:/path/b.heic` imports on launch; `INFRAMY_OPEN=editor|tv` picks a screen.
        let env = ProcessInfo.processInfo.environment
        if let list = env["INFRAMY_IMPORT"] {
            await importFiles(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }, copy: false)
        }
        switch env["INFRAMY_OPEN"] {
        case "editor": editingPhotoID = photos.first { $0.status == .needsCrop }?.id ?? photos.first?.id
        case "tv": section = .tv; editingPhotoID = nil
        case "library": editingPhotoID = nil
        default: break
        }
        // Launched by hand (not as a login item): that's opening Inframy, so wake the TV if needed.
        await autoConnect(wake: NSApp.isActive && wakeOnOpen)
        await syncAlbum(userInitiated: false)
        startPresenceLoop()
        watchForChanges()
    }

    // MARK: TV presence (SPEC §7)

    /// The Frame leaves the network while its screen sleeps (motion sensor), so nothing runs on a timer. Inframy
    /// watches for the TV to come and go (a cheap REST check every 20 s) and does what's pending when it appears:
    /// queued sends and the slideshow check. Photos rotate via the TV's own shuffle, not Inframy.
    func startPresenceLoop() {
        guard presenceTask == nil, ProcessInfo.processInfo.environment["INFRAMY_SNAPSHOT"] == nil else { return }
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.presenceTick()
            }
        }
    }

    func presenceTick() async {
        // A wake in progress does its own checking.
        guard !isWaking else { return }
        let host = SavedTV.load()?.host
        let reachable: Bool
        if let host { reachable = (try? await TVDeviceInfo.fetch(host: host, timeout: 3)) != nil } else { reachable = false }
        if reachable || !tvState.isConnected { missedChecks = 0 } else { missedChecks += 1 }
        switch (reachable, tvState.isConnected) {
        case (true, false):
            await connect()
        case (false, true):
            // A busy TV (mid-upload) can miss a 3 s check: wait for two misses, and never cut off a send.
            guard missedChecks >= 2, !isSending else { return }
            // It went to sleep. Drop the connection quietly; queued work waits for it to come back.
            if let client { await client.connection.close() }
            client = nil
            tvState = .unavailable(asleepMessage)
        case (true, true):
            if Date().timeIntervalSince(lastShuffleCheck) > 15 * 60 { await reassertShuffle() }
            await refreshCurrentArtwork()
        case (false, false):
            // Away from home there's nothing to find; back home, connect (without waking: no one asked).
            if SavedTV.load() != nil, await location() == .away {
                tvState = .away
                return
            }
            if case .away = tvState {
                await connect()
                return
            }
            // Maybe its IP changed (or it was never paired): rediscover now and then.
            if Date().timeIntervalSince(lastDiscoveryAttempt) > 180 {
                lastDiscoveryAttempt = Date()
                await connect()
            }
        }
    }

    /// Runs whenever a connection is (re)established.
    private func tvAppeared() async {
        await processPendingRemovals()
        if jobs.contains(where: { $0.stage == .waiting }) { startQueue() }
        await reassertShuffle()
    }

    var asleepMessage: String {
        "\(savedTVName) is asleep. Sends wait until it wakes."
    }

    static let awayMessage = "Not on the TV's network. Sends wait until you're home."

    var didNotWakeMessage: String {
        "\(savedTVName) didn't wake. Is Power On with Mobile on?"
    }

    private var savedTVName: String {
        SavedTV.load()?.name.replacingOccurrences(of: "[TV] ", with: "") ?? "The TV"
    }

    // MARK: Auto-connect

    /// Wake the TV when Inframy is opened or brought to the front (Settings → TV).
    var wakeOnOpen: Bool { UserDefaults.standard.bool(forKey: Prefs.wakeOnOpen) }

    /// Connects if not connected. `wake` sends Wake-on-LAN first when the TV doesn't answer and waits up to 30 s for
    /// it: only for things the user just did (opening or switching to Inframy, Send), at most once every 3 minutes,
    /// so flipping between apps doesn't keep lighting up the living room. `userAsked` (Try Again, Connect to TV)
    /// skips both the away-from-home check and that limit.
    func autoConnect(wake: Bool, userAsked: Bool = false) async {
        guard !tvState.isConnected, !isConnecting, !isWaking else { return }
        let saved = SavedTV.load()
        if !userAsked, saved != nil, await location() == .away {
            tvState = .away
            return
        }
        var wakeFailed = false
        if wake, let saved, let mac = saved.wifiMAC,
           userAsked || Date().timeIntervalSince(lastAutoWake) > 180 {
            let host = saved.host
            if (try? await TVDeviceInfo.fetch(host: host, timeout: 2)) == nil {
                lastAutoWake = Date()
                isWaking = true
                tvState = .searching("Waking \(savedTVName)…")
                let up = await WakeOnLAN.wakeUntilReachable(mac: mac) {
                    (try? await TVDeviceInfo.fetch(host: host, timeout: 1.5)) != nil
                }
                isWaking = false
                wakeFailed = !up
            }
        }
        guard !tvState.isConnected else { return }
        // Even after a failed wake: connect() also looks for the TV at a new address.
        await connect()
        if wakeFailed, tvState == .unavailable(asleepMessage) { tvState = .unavailable(didNotWakeMessage) }
    }

    /// Try Again and Connect to TV: reconnect if connected, else connect, waking the TV.
    func connectNow() async {
        if tvState.isConnected { await connect() } else { await autoConnect(wake: true, userAsked: true) }
    }

    private func location() async -> HomeNetwork.Location {
        HomeNetwork.classify(await HomeNetwork.current(), known: SavedTV.load()?.homeNetworks ?? [])
    }

    /// Reconnects when Inframy comes to the front, the Mac wakes, or the network changes.
    private func watchForChanges() {
        guard observers.isEmpty, ProcessInfo.processInfo.environment["INFRAMY_SNAPSHOT"] == nil else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.autoConnect(wake: self.wakeOnOpen)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The Mac waking (maybe in the night, maybe somewhere else) isn't anyone asking for the TV: don't wake it.
            Task { @MainActor in self?.networkChanged() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The first update is the network at launch, which start() already handled.
                if self.sawFirstPath { self.networkChanged() } else { self.sawFirstPath = true }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Joining a network sends several path updates while it settles; act once it's quiet for 2 s.
    private func networkChanged() {
        networkSettle?.cancel()
        networkSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.tvState.isConnected {
                // Left home with the lid open (or reopened it somewhere else): the connection is already dead.
                guard SavedTV.load() != nil, await self.location() == .away else { return }
                if let client = self.client { await client.connection.close() }
                self.client = nil
                self.tvState = .away
                return
            }
            await self.autoConnect(wake: false)
        }
    }

    /// 2020 Frames sometimes stop the slideshow; turn it back on if My Photos has something to show.
    func reassertShuffle() async {
        guard tvState.isConnected, UserDefaults.standard.bool(forKey: Prefs.keepShuffleOn) else { return }
        lastShuffleCheck = Date()
        // Change nothing unless both reads worked: a timed-out list must not look like "no photos".
        guard let status = try? await withClient({ try await $0.slideshowStatus() }) else { return }
        slideshow = status
        guard let personal = try? await withClient({ try await $0.contentList() }) else { return }
        if status.isOn {
            // Leave a slideshow someone chose on the TV alone, except a My Photos shuffle that's down to one photo,
            // which wedges this TV (docs/PROTOCOL.md).
            if personal.count < 2, status.categoryID == ArtProtocol.personalCategory { await setShuffle(on: false) }
        } else if personal.count >= 2 {
            await setShuffle(on: true)
        }
    }

    // MARK: Photos album (the source of truth for what's on the TV)

    /// Stored (not computed from UserDefaults) so SwiftUI notices changes; persisted on every set.
    var albumID: String? = UserDefaults.standard.string(forKey: Prefs.albumID) {
        didSet { UserDefaults.standard.set(albumID, forKey: Prefs.albumID) }
    }
    var albumTitle: String? = UserDefaults.standard.string(forKey: Prefs.albumTitle) {
        didSet { UserDefaults.standard.set(albumTitle, forKey: Prefs.albumTitle) }
    }
    var lastAlbumSync: Date? = UserDefaults.standard.object(forKey: Prefs.lastAlbumSync) as? Date
    /// Photos that left the album but still have a copy on the TV; removed once the TV is awake.
    var pendingRemovals: [LibraryPhoto] = []
    /// The user's Photos albums (for the album menu and first-run setup).
    var albums: [PhotosAlbumSync.Album] = []
    var photosAccessGranted = PhotosAlbumSync.isAuthorized

    /// Loads the album list. `requestAccess` shows the Photos permission prompt if it hasn't been answered.
    func loadAlbums(requestAccess: Bool) async {
        guard requestAccess || PhotosAlbumSync.isAuthorized else { photosAccessGranted = false; return }
        if let list = try? await PhotosAlbumSync.albums() {
            albums = list
            photosAccessGranted = true
            startWatchingAlbum()
        } else {
            photosAccessGranted = false
        }
    }

    /// Album photos too small for the TV. Shown quietly in the Library; not retried until edited in Photos.
    var albumSkipped: [PhotosAlbumSync.SkippedPhoto] = []
    private var skippedFile: URL { store.directory.appendingPathComponent("album-skipped.json") }
    /// Skipped photos still waiting for a fix (not stood in for by a full-size original).
    var uncoveredSkipped: [PhotosAlbumSync.SkippedPhoto] { albumSkipped.filter { $0.coveredBy == nil } }

    // Finding full-size originals for reduced copies in the album.
    var originalMatches: [OriginalFinder.Match] = []
    var originalProgress: OriginalFinder.Progress?
    var isFindingOriginals = false
    @ObservationIgnored private var findTask: Task<Void, Never>?

    func findOriginals() {
        guard !isFindingOriginals else { return }
        let ids = uncoveredSkipped.map(\.assetID)
        let cache = store.directory.appendingPathComponent("featureprints.plist")
        isFindingOriginals = true
        originalMatches = []
        originalProgress = OriginalFinder.Progress(phase: "Starting", done: 0, total: 0)
        findTask = Task {
            let scan = Task.detached(priority: .userInitiated) {
                await OriginalFinder.find(copies: ids, cacheURL: cache) { p in
                    Task { @MainActor in self.originalProgress = p }
                }
            }
            // A detached task doesn't inherit cancellation: pass Stop through to the scan.
            let matches = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            originalMatches = matches
            isFindingOriginals = false
        }
    }

    func cancelFindingOriginals() {
        findTask?.cancel()
        isFindingOriginals = false
    }

    /// Uses the full-size original in place of the album's reduced copy, with the copy's crop.
    func useOriginal(_ match: OriginalFinder.Match) async {
        guard let albumID else { return }
        do {
            let result = try await PhotosAlbumSync.useOriginal(match, albumID: albumID, store: store,
                                                               library: photos + pendingRemovals)
            let coveredBy: UUID
            switch result {
            case .imported(let photo):
                photos.append(photo)
                coveredBy = photo.id
            case .duplicate(let existing):
                coveredBy = existing   // the original is already in the library
            }
            if let i = albumSkipped.firstIndex(where: { $0.assetID == match.copyAssetID }) { albumSkipped[i].coveredBy = coveredBy }
            originalMatches.removeAll { $0 == match }
            saveLibrary()
            saveSkipped()
            await recognizeTVPhotos()
        } catch {
            lastError = "Couldn't use the original: \(error)"
        }
    }

    func useAllOriginals() async {
        for match in originalMatches { await useOriginal(match) }
    }

    private func loadSkipped() {
        if let data = try? Data(contentsOf: skippedFile),
           let list = try? JSONDecoder().decode([PhotosAlbumSync.SkippedPhoto].self, from: data) { albumSkipped = list }
    }

    private func saveSkipped() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(albumSkipped).write(to: skippedFile, options: .atomic)
    }
    @ObservationIgnored private var albumWatcher: PhotosAlbumSync.Watcher?
    @ObservationIgnored private var albumSyncDebounce: Task<Void, Never>?

    func chooseAlbum(_ album: PhotosAlbumSync.Album?) {
        if let album {
            guard album.id != albumID else { return }
            albumID = album.id
            albumTitle = album.title
            albumSkipped = []
            saveSkipped()
            startWatchingAlbum()
            Task { await syncAlbum(userInitiated: true) }
        } else {
            albumID = nil
            albumTitle = nil
            albumWatcher = nil
            albumSkipped = []
            saveSkipped()
        }
    }

    /// The old setting (enabled + typed name) becomes an album id.
    private func migrateAlbumSetting() async {
        let d = UserDefaults.standard
        guard albumID == nil, d.bool(forKey: Prefs.legacyAlbumSyncEnabled),
              let name = d.string(forKey: Prefs.legacyAlbumName), let id = await PhotosAlbumSync.albumID(named: name) else { return }
        albumID = id
        albumTitle = name
        d.removeObject(forKey: Prefs.legacyAlbumSyncEnabled)
    }

    /// Live sync: any change in Photos triggers a (debounced) sync of the chosen album.
    private func startWatchingAlbum() {
        guard albumID != nil, PhotosAlbumSync.isAuthorized, albumWatcher == nil else { return }
        albumWatcher = PhotosAlbumSync.Watcher { [weak self] in
            Task { @MainActor in self?.scheduleAlbumSync() }
        }
    }

    private func scheduleAlbumSync() {
        albumSyncDebounce?.cancel()
        albumSyncDebounce = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await syncAlbum(userInitiated: false)
        }
    }

    /// Brings the library in line with the album: new photos in, edits picked up, removals handled.
    func syncAlbum(userInitiated: Bool) async {
        guard let albumID, !libraryUnreadable else { return }
        guard !isSyncingAlbum else { syncAgain = true; return }
        isSyncingAlbum = true
        defer {
            isSyncingAlbum = false
            if syncAgain { syncAgain = false; scheduleAlbumSync() }
        }
        let snapshot = photos
        do {
            let result = try await PhotosAlbumSync.sync(albumID: albumID, store: store, library: photos + pendingRemovals,
                                                        skipped: albumSkipped)
            albumSkipped = result.skipped
            saveSkipped()
            albumTitle = result.albumTitle
            for photo in result.updated {
                // Merge, so a crop chosen while the sync ran isn't overwritten by the version it started from.
                guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { continue }
                let base = snapshot.first { $0.id == photo.id } ?? photos[i]
                photos[i] = LibraryPhoto.merge(base: base, current: photos[i], incoming: photo)
            }
            photos.append(contentsOf: result.imported)
            restorePendingRemovals(result.restored)
            if isMassRemoval(result.removed) {
                // An album that suddenly reads as (nearly) empty is more likely a Photos glitch than Matt's intent.
                massRemovalPrompt = MassRemoval(ids: result.removed, albumTitle: result.albumTitle)
            } else {
                massRemovalPrompt = nil  // the album recovered (or Matt removed just a few)
                handleAlbumRemovals(result.removed)
            }
            saveLibrary()
            lastAlbumSync = Date()
            UserDefaults.standard.set(lastAlbumSync, forKey: Prefs.lastAlbumSync)
            if !result.imported.isEmpty { await recognizeTVPhotos() }
            await processPendingRemovals()
            // Too-small photos are listed quietly in the Library, not in an alert.
            if !result.failures.isEmpty, userInitiated {
                lastError = "Couldn't export from \u{201C}\(result.albumTitle)\u{201D}: " + result.failures.joined(separator: ", ")
            } else if userInitiated {
                let n = result.imported.count
                lastError = n == 0 ? "\u{201C}\(result.albumTitle)\u{201D} is up to date."
                    : "\(n) new photo\(n == 1 ? "" : "s") from \u{201C}\(result.albumTitle)\u{201D}."
            }
        } catch {
            if userInitiated { lastError = String(describing: error) }
        }
    }

    /// More than a handful of photos, and at least half of the album's photos, gone in one sync.
    private func isMassRemoval(_ ids: [UUID]) -> Bool {
        guard ids.count > 5 else { return false }
        let fromAlbum = photos.filter { $0.photosAlbumID == albumID }.count
        return Double(ids.count) >= Double(fromAlbum) / 2
    }

    /// Matt's answer to the mass-removal prompt: remove them (from the TV too, per the removal setting) or keep them.
    func resolveMassRemoval(remove: Bool) async {
        guard let prompt = massRemovalPrompt else { return }
        massRemovalPrompt = nil
        if remove {
            handleAlbumRemovals(prompt.ids)
            saveLibrary()
            await processPendingRemovals()
        } else {
            // Keep them as ordinary library photos, still on the TV; they no longer follow the album.
            for id in prompt.ids {
                guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
                photos[i].photosAlbumID = nil
                photos[i].photosLocalIdentifier = nil
            }
            saveLibrary()
        }
    }

    /// Photos put back in the album before the TV woke up to delete their copy: keep them.
    private func restorePendingRemovals(_ ids: [UUID]) {
        for id in ids {
            guard let i = pendingRemovals.firstIndex(where: { $0.id == id }) else { continue }
            var photo = pendingRemovals.remove(at: i)
            photo.pendingRemoval = nil
            photos.append(photo)
        }
    }

    /// Photos that left the album: off the TV too (unless Matt chose to keep them), then out of the library.
    /// A copy Inframy only recognized on the TV (didn't upload) is left there: it shows as added outside Inframy.
    private func handleAlbumRemovals(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let keepOnTV = UserDefaults.standard.string(forKey: Prefs.albumRemoval) == "keep"
        for id in ids {
            guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
            var photo = photos.remove(at: i)
            jobs.removeAll { $0.photoID == id && !$0.isFinished }
            if keepOnTV {
                // Becomes an ordinary library photo; stays on the TV.
                photo.photosAlbumID = nil
                photo.photosLocalIdentifier = nil
                photos.insert(photo, at: min(i, photos.count))
            } else if photo.tvContentID != nil, photo.recognizedOnTV != true {
                photo.pendingRemoval = true
                pendingRemovals.append(photo)
            } else {
                store.deleteCopy(of: photo)
            }
        }
    }

    /// Deletes TV copies of photos that left the album, once the TV is awake.
    func processPendingRemovals() async {
        guard tvState.isConnected, !pendingRemovals.isEmpty else { return }
        // Check what's actually there, so a copy already deleted (on the TV, or by an earlier try) can't block
        // the rest forever.
        guard let onTV = try? await withClient({ try await $0.contentList() }).map(\.contentID) else { return }
        let ids = pendingRemovals.compactMap(\.tvContentID).filter(Set(onTV).contains)
        var deleted: [String] = []
        if !ids.isEmpty {
            if let all = try? await withClient({ try await $0.delete(ids) }) {
                deleted = all
            } else {
                // One id the TV rejects shouldn't hold up the others.
                for id in ids { deleted += (try? await withClient { try await $0.delete([id]) }) ?? [] }
            }
        }
        let gone = Set(deleted).union(pendingRemovals.compactMap(\.tvContentID).filter { !onTV.contains($0) })
        let done = pendingRemovals.filter { $0.tvContentID.map(gone.contains) ?? true }
        for photo in done { store.deleteCopy(of: photo) }
        pendingRemovals.removeAll { p in done.contains { $0.id == p.id } }
        tvItems.removeAll { gone.contains($0.contentID) }
        saveLibrary()
        if tvItems.count < 2, slideshow?.isOn == true, slideshow?.categoryID == ArtProtocol.personalCategory {
            await setShuffle(on: false)
        }
    }

    // MARK: TV

    var tvName: String {
        if case .connected(let info, _) = tvState { return info.name.replacingOccurrences(of: "[TV] ", with: "") }
        return "Frame TV"
    }

    func connect() async {
        // Connecting runs refreshTV and tvAppeared, which use withClient: don't nest another connect.
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        tvState = .searching("Looking for your Frame…")
        if let client { await client.connection.close() }
        client = nil
        do {
            let (info, saved) = try await TVLocator.resolve(note: { message in
                Task { @MainActor in self.tvState = .searching(message) }
            })
            let connection = TVLocator.connection(to: info, saved: saved)
            let c = ArtClient(connection: connection)
            let version = try await c.apiVersion()
            try await TVLocator.remember(info, connection: connection)
            // Wherever the TV answers is home (HomeNetwork).
            if var saved = SavedTV.load(), saved.id == info.id, saved.learnHomeNetwork(await HomeNetwork.current()) {
                try? saved.save()
            }
            client = c
            tvState = .connected(info, apiVersion: version)
            await refreshTV()
            await tvAppeared()
        } catch let failure as TVLocator.Failure {
            if case .pairedTVUnreachable = failure {
                // The Frame drops off the network when its motion sensor turns the screen off.
                tvState = .unavailable(asleepMessage)
            } else {
                tvState = .unavailable(String(describing: failure))
            }
        } catch {
            tvState = .unavailable(String(describing: error))
        }
    }

    /// Runs `body` against the TV. With `retry`, tries once more if the connection had dropped; the client
    /// reconnects by itself (not on timeouts: the TV may have acted on the first attempt). Never retry uploads,
    /// which aren't idempotent.
    private func withClient<T>(retry: Bool = true, _ body: (ArtClient) async throws -> T) async throws -> T {
        if client == nil { await connect() }
        guard let client else { throw AppError("Not connected to the TV.") }
        do {
            return try await body(client)
        } catch let e as ArtError {
            guard retry, case .disconnected = e else { throw e }
            return try await body(client)
        }
    }

    func refreshTV() async {
        guard client != nil else { return }
        isRefreshingTV = true
        defer { isRefreshingTV = false }
        do {
            tvItems = ContentItem.newestFirst(try await withClient { try await $0.contentList() })
            slideshow = try? await withClient { try await $0.slideshowStatus() }
            await refreshCurrentArtwork()
            // Forget TV ids that are gone (deleted on the TV or elsewhere).
            let present = Set(tvItems.map(\.contentID))
            var changed = false
            for i in photos.indices where photos[i].tvContentID.map({ !present.contains($0) }) ?? false {
                photos[i].tvContentID = nil
                photos[i].uploadedRenderKey = nil
                changed = true
            }
            if changed { saveLibrary() }
            await loadTVThumbnails()
            await recognizeTVPhotos()
        } catch ArtError.timedOut {
            // Seen on Matt's TV: the connection is up but the art service stops answering. Switching the TV to TV
            // mode and back to Art mode with the remote restarts it.
            tvState = .unavailable("The TV's art service isn't responding. Press the remote's power button to switch to TV mode and back to Art mode, then Reconnect.")
        } catch {
            lastError = "Couldn't read the TV: \(error)"
        }
    }

    private func loadTVThumbnails() async {
        for item in tvItems where tvThumbnails[item.contentID] == nil {
            let data: Data
            do {
                data = try await withClient { try await $0.thumbnail(item.contentID) }
            } catch ArtError.disconnected, ArtError.timedOut {
                return  // the TV went away: the rest load next time it's back
            } catch {
                continue
            }
            if let image = NSImage(data: data) { tvThumbnails[item.contentID] = image }
        }
    }

    /// TV items with no library photo behind them.
    var unknownTVItems: [ContentItem] { tvItems.filter { photo(forTVItem: $0.contentID) == nil } }

    /// Recognizes library photos that are already on the TV (SPEC §6): compares unmatched TV items with photos not
    /// yet on the TV, as sub-images, and records matches with the crop recovered from the TV copy. Only changes
    /// Inframy's records, never the TV. "Not the same photo" undoes a match.
    func recognizeTVPhotos() async {
        let unknown = unknownTVItems
        let candidates = photos.filter { $0.tvContentID == nil && $0.choice != .skip }
        guard !unknown.isEmpty, !candidates.isEmpty, tvState.isConnected else { return }
        var tvImages: [String: CGImage] = [:]
        for item in unknown {
            if tvThumbnails[item.contentID] == nil,
               let data = try? await withClient({ try await $0.thumbnail(item.contentID) }), let image = NSImage(data: data) {
                tvThumbnails[item.contentID] = image
            }
            if let cg = tvThumbnails[item.contentID]?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                tvImages[item.contentID] = cg
            }
        }
        let store = self.store
        let matches = await Task.detached { () -> [Recognition.Match] in
            var originals: [UUID: CGImage] = [:]
            for photo in candidates {
                if let url = store.url(for: photo), let preview = LibraryStore.thumbnail(of: url, maxPixel: 512) {
                    originals[photo.id] = preview
                }
            }
            return Recognition.match(photos: candidates, originals: originals, tvImages: tvImages)
        }.value
        guard !matches.isEmpty else { return }
        for match in matches {
            if let i = photos.firstIndex(where: { $0.id == match.photoID }) {
                photos[i] = Recognition.apply(match, to: photos[i])
            }
        }
        saveLibrary()
    }

    /// "Not the same photo": undo a recognition, and never pair these two again.
    func markNotSame(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i] = Recognition.reject(photos[i])
        saveLibrary()
    }

    /// The library photo that was uploaded as this TV item, if any.
    func photo(forTVItem id: String) -> LibraryPhoto? {
        photos.first { $0.tvContentID == id } ?? pendingRemovals.first { $0.tvContentID == id }
    }

    func deleteFromTV(_ ids: Set<String>) async {
        do {
            let deleted = try await withClient { try await $0.delete(Array(ids)) }
            let gone = Set(deleted)
            tvItems.removeAll { gone.contains($0.contentID) }
            for i in photos.indices where photos[i].tvContentID.map(gone.contains) ?? false {
                photos[i].tvContentID = nil
                photos[i].uploadedRenderKey = nil
            }
            saveLibrary()
            if gone.count < ids.count { lastError = "The TV didn't confirm deleting \(ids.count - gone.count) item(s)." }
            // Don't leave a 1-photo shuffle running: it wedges this TV (docs/PROTOCOL.md).
            if tvItems.count < 2, slideshow?.isOn == true, slideshow?.categoryID == ArtProtocol.personalCategory {
                await setShuffle(on: false)
            }
        } catch {
            lastError = "Delete failed: \(error)"
        }
    }

    func show(_ id: String) async {
        do {
            try await withClient { try await $0.select(id) }
            currentContentID = id
            // Then confirm with the TV, once it has had a moment to switch.
            try? await Task.sleep(for: .seconds(2))
            await refreshCurrentArtwork()
        } catch {
            lastError = "Couldn't show it: \(error)"
        }
    }

    /// Read-only. Never connects on its own and skips while sending, so polling can't slow an upload down.
    func refreshCurrentArtwork() async {
        guard tvState.isConnected, client != nil, !isSending else { return }
        if let current = try? await withClient(retry: false, { try await $0.currentArtwork() }) {
            currentContentID = current.contentID
        }
        if let on = try? await withClient(retry: false, { try await $0.artModeIsOn() }) { artModeOn = on }
    }

    func setShuffle(on: Bool, minutes: Int? = nil) async {
        if let minutes { shuffleMinutes = minutes }
        do {
            if on {
                // Every caller goes through here, so this is the one place the 1-photo guard has to live.
                let count = try await withClient { try await $0.contentList() }.count
                guard count >= 2 else {
                    lastError = "Shuffle needs at least 2 photos on the TV (a 1-photo shuffle wedges this TV)."
                    return
                }
            }
            try await withClient { try await $0.setSlideshow(intervalMinutes: on ? shuffleMinutes : nil) }
            slideshow = try? await withClient { try await $0.slideshowStatus() }
        } catch {
            lastError = "Couldn't change the slideshow: \(error)"
        }
    }

    // MARK: Library

    func saveLibrary() {
        guard !libraryUnreadable else { return }
        do { try store.save(photos + pendingRemovals) } catch { lastError = "Couldn't save the library: \(error)" }
    }

    /// Imports files (the `INFRAMY_IMPORT` development hook). `copy` copies them into the library.
    func importFiles(_ urls: [URL], copy: Bool) async {
        let store = self.store
        var added: [LibraryPhoto] = []
        var duplicates = 0
        var failures: [String] = []
        var tooSmall: [String] = []
        for url in urls {
            let existing = photos + added
            let result = await Task.detached { try store.importPhoto(at: url, copy: copy, existing: existing) }.result
            switch result {
            case .success(.imported(let photo)): added.append(photo)
            case .success(.duplicate): duplicates += 1
            case .failure(LibraryStore.ImportError.tooSmall(let name, let w, let h)): tooSmall.append("\(name) (\(w)×\(h))")
            case .failure: failures.append(url.lastPathComponent)
            }
        }
        photos.append(contentsOf: added)
        saveLibrary()
        var notes: [String] = []
        if duplicates > 0 { notes.append("\(duplicates) already in the library") }
        if !failures.isEmpty { notes.append("couldn't read \(failures.joined(separator: ", "))") }
        if !tooSmall.isEmpty {
            notes.append("too small for the TV (needs at least \(Panel.width)×\(Panel.height)): \(tooSmall.joined(separator: ", "))")
        }
        if !notes.isEmpty { lastError = "Imported \(added.count). " + notes.joined(separator: "; ") + "." }
        section = .library
        // Photos already on the TV are recognized (with their crop) before anything asks for a crop.
        if !added.isEmpty { await recognizeTVPhotos() }
        // Go straight to cropping the first new photo that still needs a decision.
        let addedIDs = Set(added.map(\.id))
        if editingPhotoID == nil, let first = photos.first(where: { addedIDs.contains($0.id) && $0.status == .needsCrop }) {
            editingPhotoID = first.id
        }
    }

    func update(_ photo: LibraryPhoto) {
        guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos[i] = photo
        saveLibrary()
    }

    func setSuggestedCenter(_ center: [Double], for id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].suggestedCenter = center
        saveLibrary()
    }

    func setChoice(_ choice: LibraryPhoto.Choice, for id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].choice = choice
        saveLibrary()
    }

    /// Removes photos that don't follow the current album. Album photos are removed in Photos instead (removing
    /// them here would only bring them back on the next sync), so they're ignored, whatever the caller.
    func removeFromLibrary(_ ids: Set<UUID>) {
        photos.removeAll { ids.contains($0.id) && !($0.photosAlbumID != nil && $0.photosAlbumID == albumID) }
        saveLibrary()
    }

    func url(for photo: LibraryPhoto) -> URL? { store.url(for: photo) }

    /// Small preview for grids and the filmstrip, loaded off the main thread.
    func thumbnail(for photo: LibraryPhoto) async -> NSImage? {
        if let cached = libraryThumbnails[photo.id] { return cached }
        guard let url = store.url(for: photo) else { return nil }
        let cg = await Task.detached { LibraryStore.thumbnail(of: url, maxPixel: 640) }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        libraryThumbnails[photo.id] = image
        return image
    }

    /// The next photo still waiting for a crop decision, after `id`.
    func nextUndecided(after id: UUID?) -> UUID? {
        let start = id.flatMap { id in photos.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let ordered = photos[start...] + photos[..<start]
        return ordered.first { $0.status == .needsCrop && $0.id != id }?.id
    }

    var readyToSend: [LibraryPhoto] {
        photos.filter { $0.status == .readyToSend || $0.status == .changedSinceUpload }
    }

    // MARK: Sending

    func send(_ ids: [UUID]) {
        for id in ids where !jobs.contains(where: { $0.photoID == id && !$0.isFinished }) {
            guard let photo = photos.first(where: { $0.id == id }), photo.renderSpec != nil else { continue }
            jobs.append(SendJob(photoID: id, name: photo.displayName))
        }
        // While the TV sleeps, jobs wait; they go out when it appears. Pressing Send is asking for the TV: wake it.
        if tvState.isConnected { startQueue() } else { Task { await autoConnect(wake: true) } }
    }

    private func startQueue() {
        guard !isSending else { return }
        Task { await runQueue() }
    }

    func clearFinishedJobs() { jobs.removeAll(where: \.isFinished) }

    private func runQueue() async {
        isSending = true
        defer { isSending = false }
        var sentAny = false
        while tvState.isConnected, let index = jobs.firstIndex(where: { $0.stage == .waiting }) {
            let job = jobs[index]
            guard let photo = photos.first(where: { $0.id == job.photoID }) else {
                setStage(job.id, .failed("Removed from the library"))
                continue
            }
            if photo.status == .onTV {
                // Already there (e.g. recognized after an interrupted upload landed after all).
                setStage(job.id, .done(photo.tvContentID ?? ""))
                continue
            }
            do {
                let jobID = job.id
                let updated = try await withClient(retry: false) { client in
                    try await sender.send(photo, via: client) { stage in
                        Task { @MainActor in self.apply(stage, to: jobID) }
                    }
                }
                if let i = photos.firstIndex(where: { $0.id == photo.id }) {
                    // Only what the upload changed: a re-crop or album edit made meanwhile must survive.
                    photos[i] = LibraryPhoto.merge(base: photo, current: photos[i], incoming: updated)
                    saveLibrary()
                } else if let cid = updated.tvContentID {
                    // It left the album (or library) while uploading: take back the copy Inframy just made.
                    _ = try? await withClient { try await $0.delete([cid]) }
                }
                setStage(job.id, .done(updated.tvContentID ?? ""))
                sentAny = true
            } catch let e as ArtError {
                switch e {
                case .tv(let code, _):
                    // There's no storage query; a refused upload most likely means the TV is full.
                    setStage(job.id, .failed("The TV refused it (error \(code)). It may be full."))
                    lastError = "The TV refused a photo (error \(code)). It's probably full."
                    break
                case .disconnected, .timedOut:
                    // It went to sleep mid-send. Try again when it's back (a copy that did land is recognized first).
                    if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].stage = .waiting }
                    if let client { await client.connection.close() }
                    client = nil
                    tvState = .unavailable(asleepMessage)
                default:
                    setStage(job.id, .failed(String(describing: e)))
                }
                if case .tv = e { break }
            } catch {
                setStage(job.id, .failed(String(describing: error)))
            }
        }
        if sentAny {
            await refreshTV()
            // Spec: after sending, make sure the TV is shuffling My Photos.
            if let status = slideshow, tvItems.count >= 2, !(status.isOn && status.categoryID == ArtProtocol.personalCategory) {
                await setShuffle(on: true)
            }
        }
    }

    private func apply(_ stage: PhotoSender.Stage, to jobID: UUID) {
        switch stage {
        case .rendering: setStage(jobID, .rendering)
        case .uploading: setStage(jobID, .uploading)
        case .replacing: setStage(jobID, .replacing)
        case .done: break
        }
    }

    private func setStage(_ id: UUID, _ stage: SendJob.Stage) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].isFinished { return }
        jobs[i].stage = stage
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
