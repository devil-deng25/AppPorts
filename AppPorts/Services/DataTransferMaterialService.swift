import Darwin
import Foundation

/// Finishes the display-only lifecycle of an explicitly preserved data
/// material. Neither endpoint moves, removes, mounts or changes any file or
/// volume. A missing path is not proof that an offline copy was deleted.
actor DataTransferMaterialService {
    enum RecordRemovalConfirmation: Sendable {
        /// The UI must first explain that only the record is removed, every
        /// file/volume remains, and this action does not release storage space.
        case keepAllFilesAndVolumes
    }

    enum RecheckResult: Equatable, Sendable {
        case listedPathsStillExist([String])
        /// Current and older summaries lack original parent identities. Even
        /// when every path is absent, only explicit record removal is valid.
        case absenceUnverified
        case recordAlreadyRemoved
    }

    enum RecordRemovalResult: Equatable, Sendable {
        case recordRemoved
        case alreadyRemoved
    }

    private let store: ContainerMountStore

    init(store: ContainerMountStore = .shared) { self.store = store }

    /// Read-only. Permission and I/O failures propagate; a detached volume or
    /// a missing ancestor never completes the material's record implicitly.
    func recheckPreservedMaterial(id: UUID) throws -> RecheckResult {
        guard let expected = try store.preservedMaterial(id: id) else { return .recordAlreadyRemoved }
        var existing: [String] = []
        for path in expected.paths {
            try Task.checkCancellation()
            var info = stat()
            if lstat(path, &info) == 0 { existing.append(path) }
            else if errno != ENOENT { throw DataOperationSafety.Failure.inspection(path) }
        }
        guard try store.preservedMaterial(id: id) == expected else {
            throw ContainerMountStore.StoreError.conflict("Preserved material summary changed during inspection")
        }
        return existing.isEmpty ? .absenceUnverified : .listedPathsStillExist(existing)
    }

    /// The confirmation is mandatory. The result describes only the ledger,
    /// never file deletion, volume availability, or reclaimed disk capacity.
    func removePreservedMaterialRecord(id: UUID,
                                      confirmation: RecordRemovalConfirmation) throws -> RecordRemovalResult {
        try Task.checkCancellation()
        switch confirmation {
        case .keepAllFilesAndVolumes:
            guard let expected = try store.preservedMaterial(id: id) else { return .alreadyRemoved }
            try store.removePreservedMaterialRecord(expected)
            return .recordRemoved
        }
    }
}
