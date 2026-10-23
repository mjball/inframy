import ArgumentParser
import Foundation
import InframyKit

@main
struct InframyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inframy-cli",
        abstract: "Manage your own photos on a Samsung The Frame TV.",
        discussion: """
        Finds the TV on the local network automatically (Bonjour). Run `pair` once to remember it.
        Commands that change the TV: upload, rm, show, shuffle, wake.
        """,
        subcommands: [Discover.self, Pair.self, Info.self, List.self, Thumbs.self, Suggest.self, Upload.self,
                      Remove.self, Show.self, Shuffle.self, Wake.self]
    )
}

/// Options shared by every command that talks to the TV.
struct TVOptions: ParsableArguments {
    @Option(help: "TV IP address. Default: the paired TV, else the only Frame found on the network.")
    var host: String?

    @Option(help: "Seconds to wait for the TV.")
    var timeout: Int = 20

    func resolve() async throws -> (info: TVDeviceInfo, saved: SavedTV?) {
        do {
            return try await TVLocator.resolve(host: host, note: { note($0) })
        } catch let failure as TVLocator.Failure {
            switch failure {
            case .pairedTVUnreachable: throw CLIError("\(failure) Try `inframy-cli wake`, or pass --host.")
            default: throw CLIError("\(failure) Pass --host to pick one.")
            }
        }
    }

    func client() async throws -> (ArtClient, TVDeviceInfo) {
        let (info, saved) = try await resolve()
        return (ArtClient(connection: TVLocator.connection(to: info, saved: saved, timeout: .seconds(timeout))), info)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func confirm(_ question: String) -> Bool {
    print("\(question) Type 'yes' to continue: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

// MARK: - Commands

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Frame TVs on the local network.")

    func run() async throws {
        let frames = await TVDiscovery.findFrames()
        if frames.isEmpty { throw CLIError("No Frame TV found. Is it on, and on the same network as this Mac?") }
        for f in frames {
            print("\(f.name)  \(f.host)  \(f.model ?? "?")  id=\(f.id)  mac=\(f.wifiMAC ?? "?")")
        }
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect to the TV and remember it.",
        discussion: "If the TV shows an Allow prompt, accept it with the remote.")

    @OptionGroup var tv: TVOptions

    func run() async throws {
        let info = tv.host != nil ? try await TVDeviceInfo.fetch(host: tv.host!) : try await tv.resolve().info
        guard info.isFrame else { throw CLIError("\(info.name) at \(info.host) isn't a Frame TV.") }
        // Fresh connection: no pinned certificate, so a TV that was reset can be re-paired.
        let connection = TVConnection(options: .init(host: info.host, timeout: .seconds(max(tv.timeout, 60))))
        let client = ArtClient(connection: connection)
        note("Connecting to \(info.name) at \(info.host). If the TV asks, press Allow…")
        let version = try await client.apiVersion()
        // Re-pairing replaces the pinned certificate (e.g. after a factory reset).
        try SavedTV(info: info, certificateFingerprint: await connection.certificateFingerprint).save()
        if let token = await connection.issuedToken { TokenStore.write(token, account: info.id) }
        print("Paired with \(info.name) (\(info.model ?? "?"), Art API \(version)) at \(info.host).")
        print("Saved to \(SavedTV.defaultURL.path).")
        await connection.close()
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the TV's status (read-only).")

    @OptionGroup var tv: TVOptions

    func run() async throws {
        let (client, info) = try await tv.client()
        print("TV:         \(info.name)  \(info.model ?? "")")
        print("Address:    \(info.host)  (id \(info.id), Wi-Fi MAC \(info.wifiMAC ?? "?"))")
        print("Art API:    \(try await client.apiVersion())")
        print("Art mode:   \(try await client.artModeIsOn() ? "on" : "off")")
        if let current = try? await client.currentArtwork() {
            print("Showing:    \(current.contentID)  (mat \(current.matteID ?? "?"))")
        }
        let photos = try await client.contentList()
        print("My Photos:  \(photos.count)")
        let slideshow = try await client.slideshowStatus()
        if let minutes = slideshow.intervalMinutes {
            print("Slideshow:  \(slideshow.isShuffle ? "shuffle" : "in order") every \(minutes) min, \(slideshow.categoryID ?? "?")")
        } else {
            print("Slideshow:  off")
        }
        await client.connection.close()
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List photos on the TV (read-only).")

    @OptionGroup var tv: TVOptions
    @Flag(help: "Everything on the TV, not just My Photos.") var all = false

    func run() async throws {
        let (client, _) = try await tv.client()
        let items = try await client.contentList(category: all ? nil : ArtProtocol.personalCategory)
        for item in items {
            let size = item.width.flatMap { w in item.height.map { "\(w)×\($0)" } } ?? "?"
            print([item.contentID, item.categoryID, size, "mat=\(item.matteID ?? "?")", item.contentType ?? "",
                   item.imageDate ?? ""].joined(separator: "  "))
        }
        if items.isEmpty { note("No photos\(all ? "" : " in My Photos").") }
        await client.connection.close()
    }
}

struct Thumbs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download thumbnails (read-only).")

    @OptionGroup var tv: TVOptions
    @Argument(help: "Folder to save into.") var directory: String
    @Option(parsing: .upToNextOption, help: "Only these content ids.") var ids: [String] = []
    @Flag(help: "Everything on the TV, not just My Photos.") var all = false

    func run() async throws {
        let (client, _) = try await tv.client()
        let dir = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let targets = ids.isEmpty
            ? try await client.contentList(category: all ? nil : ArtProtocol.personalCategory).map(\.contentID) : ids
        for id in targets {
            do {
                let data = try await client.thumbnail(id)
                let url = dir.appendingPathComponent("\(id).jpg")
                try data.write(to: url)
                print("\(url.path)  (\(data.count) bytes)")
            } catch {
                note("\(id): \(error)")
            }
        }
        await client.connection.close()
    }
}

struct Suggest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Suggest a starting 16:9 frame for a photo (nothing is cropped).",
        discussion: "Prints a --rect value you can adjust and pass to `upload`.")

    @Argument(help: "Photo file.") var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let image = try ImagePipeline().load(url)
        let center = CropSuggestion.center(for: image)
        let frame = CropSuggestion.initialFrame(for: image)
        print("Image:  \(Int(image.extent.width))×\(Int(image.extent.height)) (as displayed)")
        if let center {
            print(String(format: "Center: %.3f, %.3f (from faces/saliency)", center.x, center.y))
        } else {
            print("Center: none found; using the image center")
        }
        print(String(format: "--rect %.4f,%.4f,%.4f,%.4f", frame.x, frame.y, frame.width, frame.height))
    }
}

struct Upload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render photos to 3840×2160 and upload them with no mat.",
        discussion: """
        Nothing is cropped automatically. Photos that are already 16:9 are only resized. Others need either
        --rect (the 16:9 area to keep, normalized x,y,width,height from the top-left; see `suggest`) or --fit
        (whole photo over a blurred fill).
        """)

    @OptionGroup var tv: TVOptions
    @Argument(help: "Photo files.") var files: [String]
    @Option(help: "Area to keep: x,y,width,height in 0…1 from the top-left.", transform: parseRect)
    var rect: NormalizedRect?
    @Flag(help: "Show the whole photo over a blurred, darkened copy instead of cropping.") var fit = false
    @Option(help: "Mat for the uploaded photo.") var matte = "none"
    @Flag(help: "Display the last uploaded photo now (switches the TV to art mode).") var show = false
    @Option(help: "Only render the JPEGs into this folder; don't upload.") var renderOnly: String?

    func validate() throws {
        if rect != nil && fit { throw ValidationError("Use either --rect or --fit, not both.") }
        if rect != nil && files.count > 1 { throw ValidationError("--rect applies to one photo at a time.") }
    }

    func run() async throws {
        let pipeline = ImagePipeline()
        let cache = RenderCache()
        var rendered: [(file: String, url: URL)] = []
        for file in files {
            let url = URL(fileURLWithPath: file)
            let image = try pipeline.load(url)
            let aspect = image.extent.width / image.extent.height
            let mode: RenderMode
            if fit {
                mode = .fitWithBlur
            } else if let rect {
                mode = .crop(rect)
            } else if abs(aspect - Panel.aspect) / Panel.aspect < 0.005 {
                mode = .crop(.full)  // already 16:9: resize only
            } else {
                throw CLIError("""
                    \(file) is \(Int(image.extent.width))×\(Int(image.extent.height)), not 16:9. \
                    Choose the area with --rect (try `inframy-cli suggest \(file)` for a starting point) or use --fit.
                    """)
            }
            let (out, upscale) = try cache.render(url, spec: RenderSpec(mode: mode))
            if let upscale, upscale > 1.05 {
                note(String(format: "%@: upscaled %.1f× (fewer source pixels than the panel; may look soft)", file, upscale))
            }
            rendered.append((file, out))
        }

        if let renderOnly {
            let dir = URL(fileURLWithPath: renderOnly)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, url) in rendered {
                let dest = dir.appendingPathComponent(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent + "-3840x2160.jpg")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                print(dest.path)
            }
            return
        }

        let (client, info) = try await tv.client()
        var last: String?
        for (file, url) in rendered {
            let id = try await client.upload(jpeg: try Data(contentsOf: url), matte: matte)
            print("\(file) → \(id)")
            last = id
        }
        if show, let last {
            try await client.select(last)
            print("Showing \(last) on \(info.name).")
        }
        await client.connection.close()
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete photos from the TV.")

    @OptionGroup var tv: TVOptions
    @Argument(help: "Content ids, e.g. MY_F0003.") var ids: [String]
    @Flag(help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "Allow deleting items that aren't personal photos (e.g. Samsung's SAM-… art).") var force = false

    func run() async throws {
        let nonPersonal = ids.filter { !($0.hasPrefix("MY_") || $0.hasPrefix("MY-")) }
        if !nonPersonal.isEmpty && !force {
            throw CLIError("Not personal photos: \(nonPersonal.joined(separator: ", ")). Pass --force if you really mean it.")
        }
        if !yes && !confirm("Delete \(ids.joined(separator: ", ")) from the TV? This can't be undone.") {
            throw CLIError("Cancelled.")
        }
        let (client, _) = try await tv.client()
        let deleted = try await client.delete(ids)
        print("Deleted: \(deleted.joined(separator: ", "))")
        let missed = Set(ids).subtracting(deleted)
        if !missed.isEmpty { note("The TV didn't confirm: \(missed.sorted().joined(separator: ", "))") }
        await client.connection.close()
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display a photo now (switches the TV to art mode).")

    @OptionGroup var tv: TVOptions
    @Argument(help: "Content id.") var id: String

    func run() async throws {
        let (client, _) = try await tv.client()
        try await client.select(id, category: id.hasPrefix("MY") ? ArtProtocol.personalCategory : nil)
        print("Showing \(id).")
        await client.connection.close()
    }
}

struct Shuffle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Turn the My Photos slideshow on or off.")

    enum State: String, ExpressibleByArgument { case on, off }

    @OptionGroup var tv: TVOptions
    @Argument(help: "on or off.") var state: State
    @Option(help: "Minutes between photos. The TV accepts any value; prefer ones its menu offers.") var interval = 15
    @Flag(help: "In order instead of shuffled.") var ordered = false

    func run() async throws {
        let (client, _) = try await tv.client()
        try await client.setSlideshow(intervalMinutes: state == .on ? interval : nil, shuffle: !ordered)
        let status = try await client.slideshowStatus()
        if let minutes = status.intervalMinutes {
            print("Slideshow on: \(status.isShuffle ? "shuffle" : "in order") every \(minutes) min (\(status.contentIDs.count) photo\(status.contentIDs.count == 1 ? "" : "s")).")
        } else {
            print("Slideshow off.")
        }
        await client.connection.close()
    }
}

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wake the paired TV with Wake-on-LAN.")

    func run() throws {
        guard let saved = SavedTV.load(), let mac = saved.wifiMAC else {
            throw CLIError("No paired TV with a known MAC address. Run `pair` first.")
        }
        try WakeOnLAN.wake(mac: mac)
        print("Sent Wake-on-LAN to \(saved.name) (\(mac)).")
    }
}

func parseRect(_ text: String) throws -> NormalizedRect {
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, parts.allSatisfy({ (0...1).contains($0) }), parts[2] > 0, parts[3] > 0,
          parts[0] + parts[2] <= 1.0001, parts[1] + parts[3] <= 1.0001 else {
        throw ValidationError("--rect wants x,y,width,height between 0 and 1, inside the image (e.g. 0,0.1,1,0.75).")
    }
    return NormalizedRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}
