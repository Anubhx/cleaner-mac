import Foundation
import Darwin
import UniformTypeIdentifiers
@preconcurrency import QuickLookThumbnailing
import CleanerCore

enum MetadataSnapshotProvider {
    static func capture(for item: ScannedItem) async -> FileMetadataSnapshot {
        let url = item.url
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .linkCountKey,
        ])

        let utType = values?.contentType
            ?? (item.isDirectory ? .folder : UTType(filenameExtension: url.pathExtension))
        let uti = utType?.identifier ?? (item.isDirectory ? "public.folder" : "public.data")
        let kind = values?.localizedTypeDescription ?? utType?.localizedDescription ?? "Document"

        let posix = readPOSIXPermissions(at: url)
        let xattrs = readExtendedAttributes(at: url)
        let thumbnail = Task.isCancelled ? nil : await generateQuickLookThumbnail(for: url)

        return FileMetadataSnapshot(
            url: url,
            utiIdentifier: uti,
            kindDescription: kind,
            logicalSize: UInt64(max(0, values?.fileSize ?? Int(item.logicalSize))),
            allocatedSize: UInt64(max(0, values?.fileAllocatedSize ?? Int(item.allocatedSize))),
            createdDate: values?.creationDate ?? item.createdDate,
            modifiedDate: values?.contentModificationDate ?? item.modifiedDate,
            accessedDate: values?.contentAccessDate ?? item.accessedDate,
            posixPermissions: posix,
            linkCount: values?.linkCount ?? item.linkCount,
            extendedAttributes: xattrs,
            thumbnail: thumbnail
        )
    }

    private static func readPOSIXPermissions(at url: URL) -> String {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return "---------" }
        let mode = info.st_mode
        let bits: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
            (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
            (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x"),
        ]
        let perms = String(bits.map { (mode & $0.0) != 0 ? $0.1 : "-" })
        let octal = String(format: "%03o", mode & 0o777)
        return "\(perms) (\(octal))"
    }

    private static func readExtendedAttributes(at url: URL) -> [String] {
        let path = url.path(percentEncoded: false)
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let readCount = listxattr(path, &buffer, length, XATTR_NOFOLLOW)
        guard readCount > 0 else { return [] }

        let data = Data(bytes: buffer, count: readCount)
        return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private static func generateQuickLookThumbnail(for url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 240),
            scale: 2.0,
            representationTypes: .all
        )
        return await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}
