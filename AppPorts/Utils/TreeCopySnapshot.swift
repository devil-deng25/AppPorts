import Foundation

/// A content and metadata manifest. Paths are relative to the selected root.
/// Source identities support checking a retained original after a rename.
struct TreeCopySnapshot: Codable, Equatable, Sendable {
    struct Ownership: Codable, Equatable, Sendable {
        let uid: UInt32
        let gid: UInt32
    }

    /// `noowners` reports an effective owner, not the stored UID/GID. Keep the
    /// source and destination contracts separate so a compatible destination
    /// never weakens verification of an ownership-aware retained original.
    struct OwnershipCompatibility: Codable, Equatable, Sendable {
        let sourceIgnoresOwnership: Bool
        var destinationIgnoresOwnership: Bool
        /// A source with projected ownership is copied as the current user.
        /// Store that choice instead of interpreting its observed UID as real.
        let projectedSourceOwner: Ownership?
    }

    struct Identity: Codable, Equatable, Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    struct Timestamp: Codable, Equatable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64
    }

    struct Entry: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case directory, file, symbolicLink }
        let path: String
        let kind: Kind
        let identity: Identity
        let mode: UInt16
        let uid: UInt32
        let gid: UInt32
        let flags: UInt32
        let birthTime: Timestamp
        let modificationTime: Timestamp
        let extendedAttributes: [String: Data]
        let acl: String?
        let size: Int64
        let digest: Data?
        let linkTarget: String?
        let hardlinkGroup: String?
    }

    /// Only legacy mount restores may preserve the formerly projected root owner.
    /// entries always retain the actual source ownership for unchanged/cleanup checks.
    var restoredRootOwnership: Ownership? = nil

    /// Absent in historical manifests: both sides require real ownership.
    /// Entries remain observations of the source, including projected IDs.
    var ownershipCompatibility: OwnershipCompatibility? = nil

    func destinationEntry(_ entry: Entry) -> Entry {
        let owner = entry.path.isEmpty ? restoredRootOwnership ?? ownershipCompatibility?.projectedSourceOwner
                                      : ownershipCompatibility?.projectedSourceOwner
        guard let owner else { return entry }
        return Entry(path: entry.path, kind: entry.kind, identity: entry.identity, mode: entry.mode,
                     uid: owner.uid, gid: owner.gid, flags: entry.flags, birthTime: entry.birthTime,
                     modificationTime: entry.modificationTime, extendedAttributes: entry.extendedAttributes,
                     acl: entry.acl, size: entry.size, digest: entry.digest, linkTarget: entry.linkTarget,
                     hardlinkGroup: entry.hardlinkGroup)
    }

    let entries: [Entry]
    let excludedRootEntries: Set<String>
    var logicalBytes: Int64 { entries.filter { $0.kind == .file }.reduce(0) { $0 + $1.size } }
}
