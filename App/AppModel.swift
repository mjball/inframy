import AppKit
import InframyKit
import Observation
import SwiftUI

/// App state. Thin on purpose: the logic lives in InframyKit.
@Observable @MainActor
final class AppModel {
    enum TVState: Equatable {
        case searching(String)
        case connected(TVDeviceInfo, apiVersion: String)
        case unavailable(String)

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
    var slideshow: SlideshowStatus?
    var jobs: [SendJob] = []
    var section: Section = .library
    /// Photo open in the crop editor.
    var editingPhotoID: UUID?
    var lastError: String?
    var isRefreshingTV = false
    var isSyncingAlbum = false
    var isRotating = false
    var lastRotation: Date? = UserDefaults.standard.object(forKey: Prefs.lastRotation) as? Date

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored private let sender: PhotoSender
    @ObservationIgnored private var client: ArtClient?
    @ObservationIgnored private var libraryThumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var isSending = false

    /// Preferred slideshow interval when Inframy turns shuffle on.
    var shuffleMinutes: Int {
        get { UserDefaults.standard.object(forKey: Prefs.shuffleMinutes) as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.shuffleMinutes) }
    }

    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

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
        photos = store.load()
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
        await connect()
        await syncAlbum(userInitiated: false)
        startBackgroundLoop()
    }

    // MARK: Background (SPEC §7)

    /// Every 15 minutes while Inframy runs: keep the slideshow on, and rotate the pool when it's due.
    func startBackgroundLoop() {
        guard backgroundTask == nil, ProcessInfo.processInfo.environment["INFRAMY_SNAPSHOT"] == nil else { return }
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                await self?.backgroundTick()
            }
        }
    }

    func backgroundTick() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Prefs.rotationEnabled), rotationDue {
            await rotate(userInitiated: false)
        }
        if defaults.bool(forKey: Prefs.keepShuffleOn) { await reassertShuffle() }
    }

    var rotationDue: Bool {
        let hours = UserDefaults.standard.integer(forKey: Prefs.rotationHours)
        guard let last = lastRotation else { return true }
        return Date().timeIntervalSince(last) >= Double(max(hours, 1)) * 3600
    }

    /// 2020 Frames sometimes stop the slideshow; turn it back on if My Photos has something to show.
    func reassertShuffle() async {
        if !tvState.isConnected { await connect() }
        guard tvState.isConnected else { return }
        guard let status = try? await withClient({ try await $0.slideshowStatus() }) else { return }
        slideshow = status
        let personal = (try? await withClient { try await $0.contentList() }) ?? []
        // A single-photo shuffle wedged Matt's 2020 Frame (docs/PROTOCOL.md): only shuffle two or more,
        // and switch off a shuffle that's down to one.
        if personal.count >= 2, !(status.isOn && status.categoryID == ArtProtocol.personalCategory) {
            await setShuffle(on: true)
        } else if personal.count < 2, status.isOn, status.categoryID == ArtProtocol.personalCategory {
            await setShuffle(on: false)
        }
    }

    /// One rotation: upload the longest-absent photos, then take down the oldest Inframy photos (SPEC §7).
    func rotate(userInitiated: Bool) async {
        guard !isRotating else { return }
        isRotating = true
        defer { isRotating = false }
        let defaults = UserDefaults.standard
        if !tvState.isConnected { await connect() }
        if !tvState.isConnected, defaults.bool(forKey: Prefs.wakeForRotation), let mac = SavedTV.load()?.wifiMAC {
            try? WakeOnLAN.wake(mac: mac)
            try? await Task.sleep(for: .seconds(20))
            await connect()
        }
        guard tvState.isConnected, let client else {
            if userInitiated { lastError = "Can't rotate: the TV isn't reachable." }
            return
        }
        let pool = defaults.integer(forKey: Prefs.poolSize)
        let plan = RotationPlanner.plan(photos: photos, poolSize: pool,
                                        swapFraction: Double(defaults.integer(forKey: Prefs.swapPercent)) / 100)
        if !plan.isEmpty {
            let outcome = await Rotator(sender: sender).run(plan, photos: photos, client: client)
            for p in outcome.updated { if let i = photos.firstIndex(where: { $0.id == p.id }) { photos[i] = p } }
            saveLibrary()
            if outcome.probablyFull {
                // No storage query exists: treat a TV-side upload failure as "full" and shrink the pool to fit.
                let onTV = photos.filter { $0.tvContentID != nil }.count
                defaults.set(max(5, onTV), forKey: Prefs.poolSize)
                lastError = "The TV seems to be full, so the pool is now \(max(5, onTV)) photos."
            } else if !outcome.failures.isEmpty, userInitiated {
                lastError = "Rotation finished with problems:\n" + outcome.failures.joined(separator: "\n")
            }
            await refreshTV()
        }
        lastRotation = Date()
        defaults.set(lastRotation, forKey: Prefs.lastRotation)
    }

    func togglePin(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].pinned = photos[i].pinned == true ? nil : true
        saveLibrary()
    }

    // MARK: Photos album

    var albumSyncEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.albumSyncEnabled) }
    var albumName: String { UserDefaults.standard.string(forKey: Prefs.albumName) ?? PhotosAlbumSync.defaultAlbumName }

    /// Imports new photos from the configured Photos album. Quiet unless the user asked or something was added.
    func syncAlbum(userInitiated: Bool) async {
        guard albumSyncEnabled, !isSyncingAlbum else { return }
        isSyncingAlbum = true
        defer { isSyncingAlbum = false }
        do {
            let result = try await PhotosAlbumSync.sync(albumName: albumName, store: store, library: photos)
            for photo in result.linked { if let i = photos.firstIndex(where: { $0.id == photo.id }) { photos[i] = photo } }
            photos.append(contentsOf: result.imported)
            if !result.imported.isEmpty || !result.linked.isEmpty { saveLibrary() }
            if !result.imported.isEmpty { await recognizeTVPhotos() }
            if userInitiated || !result.imported.isEmpty || !result.failures.isEmpty {
                var text = "\(result.imported.count) new photo\(result.imported.count == 1 ? "" : "s") from \"\(albumName)\"."
                if !result.failures.isEmpty { text += " Couldn't export: \(result.failures.joined(separator: ", "))." }
                lastError = text
            }
        } catch {
            if userInitiated { lastError = String(describing: error) }
        }
    }

    // MARK: TV

    var tvName: String {
        if case .connected(let info, _) = tvState { return info.name.replacingOccurrences(of: "[TV] ", with: "") }
        return "Frame TV"
    }

    func connect() async {
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
            client = c
            tvState = .connected(info, apiVersion: version)
            await refreshTV()
        } catch let failure as TVLocator.Failure {
            if case .pairedTVUnreachable(let tv) = failure {
                // The Frame drops off the network when its motion sensor turns the screen off.
                tvState = .unavailable("\(tv.name.replacingOccurrences(of: "[TV] ", with: "")) is asleep or off the network. It wakes when someone walks in (motion sensor), or try Wake TV.")
            } else {
                tvState = .unavailable(String(describing: failure))
            }
        } catch {
            tvState = .unavailable(String(describing: error))
        }
    }

    func wake() {
        guard let mac = SavedTV.load()?.wifiMAC else { return }
        try? WakeOnLAN.wake(mac: mac)
        Task {
            try? await Task.sleep(for: .seconds(8))
            await connect()
        }
    }

    /// Runs `body` against the TV, reconnecting once if the connection dropped.
    /// Runs `body` against the TV. With `retry`, reconnects and tries once more if the connection had dropped
    /// (not on timeouts: the TV may have acted on the first attempt). Never retry uploads, which aren't idempotent.
    private func withClient<T>(retry: Bool = true, _ body: (ArtClient) async throws -> T) async throws -> T {
        if client == nil { await connect() }
        guard let client else { throw AppError("Not connected to the TV.") }
        do {
            return try await body(client)
        } catch let e as ArtError {
            guard retry, case .disconnected = e else { throw e }
            await connect()
            guard let again = self.client else { throw e }
            return try await body(again)
        }
    }

    func refreshTV() async {
        guard client != nil else { return }
        isRefreshingTV = true
        defer { isRefreshingTV = false }
        do {
            tvItems = try await withClient { try await $0.contentList() }
            slideshow = try? await withClient { try await $0.slideshowStatus() }
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
            guard let data = try? await withClient({ try await $0.thumbnail(item.contentID) }),
                  let image = NSImage(data: data) else { continue }
            tvThumbnails[item.contentID] = image
        }
    }

    /// TV items with no library photo behind them.
    var unknownTVItems: [ContentItem] { tvItems.filter { photo(forTVItem: $0.contentID) == nil } }

    /// Compares unknown TV items with library photos by perceptual hash and proposes links. Never links or
    /// deletes anything by itself.
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
    func photo(forTVItem id: String) -> LibraryPhoto? { photos.first { $0.tvContentID == id } }

    func deleteFromTV(_ ids: Set<String>) async {
        do {
            let deleted = try await withClient { try await $0.delete(Array(ids)) }
            let gone = Set(deleted)
            tvItems.removeAll { gone.contains($0.contentID) }
            for i in photos.indices where photos[i].tvContentID.map(gone.contains) ?? false {
                photos[i].tvContentID = nil
                photos[i].uploadedRenderKey = nil
                photos[i].onTVSince = nil
                photos[i].lastOnTV = Date()
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
        do { try await withClient { try await $0.select(id) } } catch { lastError = "Couldn't show it: \(error)" }
    }

    func setShuffle(on: Bool, minutes: Int? = nil) async {
        if let minutes { shuffleMinutes = minutes }
        do {
            try await withClient { try await $0.setSlideshow(intervalMinutes: on ? shuffleMinutes : nil) }
            slideshow = try? await withClient { try await $0.slideshowStatus() }
        } catch {
            lastError = "Couldn't change the slideshow: \(error)"
        }
    }

    // MARK: Library

    func saveLibrary() {
        do { try store.save(photos) } catch { lastError = "Couldn't save the library: \(error)" }
    }

    /// Imports files. `copy` for files that are only temporary (Photos drags, the Photos picker).
    func importFiles(_ urls: [URL], copy: Bool) async {
        let store = self.store
        var added: [LibraryPhoto] = []
        var duplicates = 0
        var failures: [String] = []
        for url in urls {
            let existing = photos + added
            let result = await Task.detached { try store.importPhoto(at: url, copy: copy, existing: existing) }.result
            switch result {
            case .success(.imported(let photo)): added.append(photo)
            case .success(.duplicate): duplicates += 1
            case .failure: failures.append(url.lastPathComponent)
            }
        }
        photos.append(contentsOf: added)
        saveLibrary()
        var notes: [String] = []
        if duplicates > 0 { notes.append("\(duplicates) already in the library") }
        if !failures.isEmpty { notes.append("couldn't read \(failures.joined(separator: ", "))") }
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

    func setChoice(_ choice: LibraryPhoto.Choice, for id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].choice = choice
        saveLibrary()
    }

    func removeFromLibrary(_ ids: Set<UUID>) {
        photos.removeAll { ids.contains($0.id) }
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
        guard !isSending else { return }
        Task { await runQueue() }
    }

    func clearFinishedJobs() { jobs.removeAll(where: \.isFinished) }

    private func runQueue() async {
        isSending = true
        defer { isSending = false }
        var sentAny = false
        while let index = jobs.firstIndex(where: { $0.stage == .waiting }) {
            let job = jobs[index]
            guard let photo = photos.first(where: { $0.id == job.photoID }) else {
                setStage(job.id, .failed("Removed from the library"))
                continue
            }
            do {
                let jobID = job.id
                let updated = try await withClient(retry: false) { client in
                    try await sender.send(photo, via: client) { stage in
                        Task { @MainActor in self.apply(stage, to: jobID) }
                    }
                }
                update(updated)
                setStage(job.id, .done(updated.tvContentID ?? ""))
                sentAny = true
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
