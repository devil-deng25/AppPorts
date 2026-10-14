import Darwin
import Foundation

enum DataOperationIssue {
    static func needsAccessPermission(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        switch error {
        case DataOperationSafety.Failure.accessDenied:
            return true
        case ContainerVolumeMigrator.AutomaticRecoveryError.restored(let operation, _):
            return needsAccessPermission(operation, depth: depth + 1)
        case ContainerVolumeMigrator.AutomaticRecoveryError.incomplete(let operation, let recovery):
            return needsAccessPermission(operation, depth: depth + 1) || needsAccessPermission(recovery, depth: depth + 1)
        case ContainerVolumeMigrator.MigrationError.copyFailed(let underlying):
            return needsAccessPermission(underlying, depth: depth + 1)
        case ContainerVolumeMigrator.MigrationError.ownershipRollbackFailed(_, let operation, let rollback):
            return needsAccessPermission(operation, depth: depth + 1) || needsAccessPermission(rollback, depth: depth + 1)
        case DiskUtility.Failure.administratorPromptCancelled, DiskUtility.Failure.privilegeRequired:
            return false
        default: break
        }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(value.code) { return true }
        if value.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error,
           needsAccessPermission(underlying, depth: depth + 1) { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("operation not permitted") || message.contains("permission denied")
    }
}
