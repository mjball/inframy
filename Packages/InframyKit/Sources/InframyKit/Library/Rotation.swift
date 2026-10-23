import Foundation

/// Pool rotation (SPEC §7): the library can be much bigger than the TV holds. Keep `poolSize` photos on the TV,
/// and every so often swap a fraction of them for the photos that have been off the TV longest. The TV's own
/// shuffle handles minute-to-minute changes.
public enum RotationPlanner {
    public struct Plan: Sendable, Equatable {
        /// Library photos to upload.
        public var upload: [UUID]
        /// Library photos to take off the TV (they were uploaded by Inframy).
        public var remove: [UUID]

        public var isEmpty: Bool { upload.isEmpty && remove.isEmpty }
    }

    /// - Parameters:
    ///   - poolSize: target number of Inframy photos on the TV.
    ///   - swapFraction: share of the pool replaced per rotation (e.g. 0.2).
    /// Photos eligible to go up: Matt has chosen a crop or Fit (never undecided or skipped).
    /// Pinned photos stay up and count toward the pool.
    public static func plan(photos: [LibraryPhoto], poolSize: Int, swapFraction: Double) -> Plan {
        let onTV = photos.filter { $0.tvContentID != nil }
        let offTV = photos.filter { $0.tvContentID == nil && $0.renderSpec != nil }
        let size = max(poolSize, 0)

        // Longest-absent first; never-shown photos count as absent since they were added.
        let comingUp = offTV.sorted { ($0.lastOnTV ?? $0.addedAt, $0.id.uuidString) < ($1.lastOnTV ?? $1.addedAt, $1.id.uuidString) }
        // Oldest on the TV first; pinned never leave.
        let goingDown = onTV.filter { $0.pinned != true }
            .sorted { ($0.onTVSince ?? .distantPast, $0.id.uuidString) < ($1.onTVSince ?? .distantPast, $1.id.uuidString) }

        if onTV.count > size {
            // Over the pool (e.g. it was shrunk because the TV is full): just remove the oldest.
            return Plan(upload: [], remove: Array(goingDown.prefix(onTV.count - size)).map(\.id))
        }
        // Fill any free slots first.
        let free = size - onTV.count
        var upload = Array(comingUp.prefix(free))
        var remaining = Array(comingUp.dropFirst(free))
        // Then swap a fraction of the pool, limited by what's available to swap in and take down.
        let swaps = min(Int((Double(size) * swapFraction).rounded()), remaining.count, goingDown.count)
        let swapIn = remaining.prefix(swaps)
        remaining.removeFirst(swaps)
        upload += swapIn
        let remove = goingDown.prefix(swaps)
        return Plan(upload: upload.map(\.id), remove: remove.map(\.id))
    }
}

/// Runs a rotation plan against the TV: uploads first, then removes, so the TV never runs short of photos.
public struct Rotator: Sendable {
    public let sender: PhotoSender

    public init(sender: PhotoSender = PhotoSender()) { self.sender = sender }

    public struct Outcome: Sendable {
        public var updated: [LibraryPhoto] = []
        public var failures: [String] = []
        /// Set when an upload failed in a way that suggests the TV is out of space.
        public var probablyFull = false
    }

    public func run(_ plan: Plan, photos: [LibraryPhoto], client: ArtClient) async -> Outcome {
        var out = Outcome()
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var uploaded = 0
        for id in plan.upload {
            guard let photo = byID[id] else { continue }
            do {
                out.updated.append(try await sender.send(photo, via: client))
                uploaded += 1
            } catch let e as ArtError {
                out.failures.append("\(photo.displayName): \(e)")
                // There's no storage query. A TV-side failure after earlier uploads in this run worked is the
                // best signal that it's full (SPEC §7): stop uploading.
                if case .tv = e { out.probablyFull = true; break }
            } catch {
                out.failures.append("\(photo.displayName): \(error)")
            }
        }
        // Only take photos down if their replacements went up (keep the pool from shrinking on failures),
        // except when the plan is purely a shrink.
        let removable = plan.upload.isEmpty ? plan.remove : Array(plan.remove.prefix(uploaded))
        let contentIDs = removable.compactMap { byID[$0]?.tvContentID }
        if !contentIDs.isEmpty {
            do {
                let deleted = Set(try await client.delete(contentIDs))
                for id in removable {
                    guard var p = byID[id], let cid = p.tvContentID, deleted.contains(cid) else { continue }
                    p.tvContentID = nil
                    p.uploadedRenderKey = nil
                    p.onTVSince = nil
                    p.lastOnTV = Date()
                    out.updated.append(p)
                }
            } catch {
                out.failures.append("Removing old photos: \(error)")
            }
        }
        return out
    }

    public typealias Plan = RotationPlanner.Plan
}
