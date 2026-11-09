import Foundation

public enum SafetyError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case protectedPath(String)
    case outsideUserScope(String)
    case appBundleProtected(String)
    case userExcluded(String)
    case symlinkEscape(String)
    case tooManyFiles(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Invalid or malformed path: \(path)"
        case .protectedPath(let path):
            "Protected macOS system or Library path cannot be modified: \(path)"
        case .outsideUserScope(let path):
            "Path belongs to another user account and is off-limits: \(path)"
        case .appBundleProtected(let path):
            "Application bundles are protected unless explicitly selected: \(path)"
        case .userExcluded(let path):
            "Path is inside a user-excluded folder: \(path)"
        case .symlinkEscape(let path):
            "Symlink resolves outside the authorized scope into a protected target: \(path)"
        case .tooManyFiles(let count):
            "Batch exceeds the safety limit of \(SafetyGuard.maxFilesPerOperation) items (attempted \(count))"
        }
    }
}
