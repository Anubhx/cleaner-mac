import Testing
import Foundation
@testable import CleanerCore

@Suite("SafetyGuard Protected-Path & Symlink Rules")
struct SafetyGuardTests {
    private let currentUserHome = URL(fileURLWithPath: "/Users/alice")
    private let guardPolicy = SafetyGuard(currentUserHome: URL(fileURLWithPath: "/Users/alice"))

    @Test("Rejects empty path and NUL byte injection")
    func rejectsInvalidPaths() {
        #expect(throws: SafetyError.invalidPath("(empty)")) {
            try guardPolicy.validatePath(URL(fileURLWithPath: ""))
        }
        #expect(throws: SafetyError.invalidPath("/Users/alice/Downloads/bad\0file")) {
            try guardPolicy.validateRawPath("/Users/alice/Downloads/bad\0file")
        }
    }

    @Test("Blocks protected system and Library prefixes")
    func blocksSystemPrefixes() {
        let forbidden = [
            "/System/Library/CoreServices/Finder.app",
            "/Library/Preferences/com.apple.loginwindow.plist",
            "/usr/bin/env",
            "/bin/zsh",
            "/sbin/mount",
            "/private/etc/hosts",
            "/private/var/db/receipts",
            "/dev/null",
        ]
        for path in forbidden {
            #expect(throws: SafetyError.self) {
                try guardPolicy.validatePath(URL(fileURLWithPath: path))
            }
        }
    }

    @Test("Blocks other users home directories while allowing current user")
    func blocksOtherUsersHome() throws {
        #expect(throws: SafetyError.outsideUserScope("/Users/bob/Downloads/secret.pdf")) {
            try guardPolicy.validatePath(URL(fileURLWithPath: "/Users/bob/Downloads/secret.pdf"))
        }
        try guardPolicy.validatePath(
            currentUserHome.appendingPathComponent("Downloads/old.zip")
        )
    }

    @Test("Blocks app bundles unless explicitly allowed")
    func blocksAppBundlesByDefault() throws {
        let userApp = currentUserHome.appendingPathComponent("Applications/CustomApp.app")
        #expect(throws: SafetyError.appBundleProtected(userApp.path)) {
            try guardPolicy.validatePath(userApp, allowAppBundles: false)
        }
        try guardPolicy.validatePath(userApp, allowAppBundles: true)
    }

    @Test("Respects user-excluded folders on path component boundaries")
    func respectsExcludedFoldersWithoutPrefixBug() throws {
        let excluded = ["/Users/alice/Projects"]
        let blocked = URL(fileURLWithPath: "/Users/alice/Projects/app/build.log")
        let allowedSibling = URL(fileURLWithPath: "/Users/alice/ProjectsBackup/old.zip")

        #expect(throws: SafetyError.userExcluded(blocked.path)) {
            try guardPolicy.validatePath(blocked, excludedFolders: excluded)
        }
        try guardPolicy.validatePath(allowedSibling, excludedFolders: excluded)
    }

    @Test("Rejects symlinks that escape into protected directories")
    func rejectsSymlinkEscape() {
        let linkURL = URL(fileURLWithPath: "/Users/alice/Downloads/shortcut")
        let resolvedSystem = URL(fileURLWithPath: "/System/Library/Speech")
        #expect(throws: SafetyError.symlinkEscape(resolvedSystem.path)) {
            try guardPolicy.validateResolvedTarget(original: linkURL, resolved: resolvedSystem)
        }
    }

    @Test("Canonicalizes macOS firmlinks consistently")
    func canonicalizesFirmlinks() {
        #expect(SafetyGuard.canonicalizeFirmlink("/private/var/folders/xx") == "/var/folders/xx")
        #expect(SafetyGuard.canonicalizeFirmlink("/private/tmp/test") == "/tmp/test")
        #expect(SafetyGuard.canonicalizeFirmlink("/private/etc/hosts") == "/etc/hosts")
    }

    @Test("Rejects unchunked batch exceeding safety operation limit")
    func enforcesBatchLimit() {
        let urls = (0..<(SafetyGuard.maxFilesPerOperation + 1)).map {
            URL(fileURLWithPath: "/Users/alice/Downloads/file-\($0).tmp")
        }
        #expect(throws: SafetyError.tooManyFiles(SafetyGuard.maxFilesPerOperation + 1)) {
            try guardPolicy.validateBatch(urls)
        }
    }
}

