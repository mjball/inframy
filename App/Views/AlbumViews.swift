import InframyKit
import SwiftUI

/// The toolbar's album menu: the album Inframy keeps on the TV, switching albums, and Sync Now.
struct AlbumToolbarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if !model.photosAccessGranted {
                Button("Allow Access to Photos…") { Task { await model.loadAlbums(requestAccess: true) } }
            } else {
                Section("Photos album for the TV") {
                    ForEach(model.albums) { album in
                        Button {
                            model.chooseAlbum(album)
                        } label: {
                            if album.id == model.albumID {
                                Label(AlbumLabel.text(album), systemImage: "checkmark")
                            } else {
                                Text(AlbumLabel.text(album))
                            }
                        }
                        .disabled(album.isShared)
                    }
                }
                if model.albumID != nil {
                    Divider()
                    Button("Sync Now") { Task { await model.syncAlbum(userInitiated: true) } }
                        .disabled(model.isSyncingAlbum)
                    if let last = model.lastAlbumSync {
                        Text("Last synced \(last.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
        } label: {
            Label(model.albumTitle ?? "Choose Album", systemImage: "photo.on.rectangle.angled")
                .labelStyle(.titleAndIcon)
        }
        .help("The Photos album Inframy keeps on your TV")
        .task { await model.loadAlbums(requestAccess: false) }
    }
}

enum AlbumLabel {
    static func text(_ album: PhotosAlbumSync.Album) -> String {
        album.isShared ? "\(album.title) (shared album: too small for the TV)" : "\(album.title)  (\(album.photoCount))"
    }
}

/// First run: no album chosen yet. Choosing one is the only way photos get into Inframy.
struct AlbumSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Choose the Photos album for your TV").font(.title2.weight(.semibold))
            Text("Inframy keeps your TV in step with one album in Photos. Add a photo to the album and it shows up here for you to crop; take it out and it leaves the TV. Inframy only reads from Photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if !model.photosAccessGranted {
                Button("Allow Access to Photos…") { Task { await model.loadAlbums(requestAccess: true) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if model.albums.isEmpty {
                ProgressView()
            } else {
                List(model.albums) { album in
                    Button {
                        model.chooseAlbum(album)
                    } label: {
                        HStack {
                            Image(systemName: album.isShared ? "person.2" : "rectangle.stack")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(album.title)
                            Spacer()
                            Text(album.isShared ? "shared: too small for the TV" : "\(album.photoCount) photos")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(album.isShared)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 520, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.loadAlbums(requestAccess: false) }
    }
}

/// An album is chosen but has nothing in it (yet).
struct EmptyAlbumView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("\u{201C}\(model.albumTitle ?? "The album")\u{201D} is empty", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add photos to it in Photos and they'll appear here within a few seconds. Photos need to be at least 3840×2160.")
        } actions: {
            Button("Sync Now") { Task { await model.syncAlbum(userInitiated: true) } }
        }
    }
}
