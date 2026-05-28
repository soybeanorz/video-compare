import Foundation
import UniformTypeIdentifiers

enum MediaFileSupport {
    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "dng"]
    static let rawImageExtensions: Set<String> = [
        "dng", "arw", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf", "pef",
        "srw", "x3f", "erf", "rwl", "3fr", "fff", "iiq", "mos", "mrw"
    ]

    static var allowedContentTypes: [UTType] {
        let videoTypes = videoExtensions.compactMap { UTType(filenameExtension: $0) }
        return videoTypes + [.image]
    }

    static func isSupported(_ url: URL) -> Bool {
        isSupportedExtension(url.pathExtension)
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isRawImage(_ url: URL) -> Bool {
        rawImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupportedExtension(_ ext: String) -> Bool {
        let normalized = ext.lowercased()
        return videoExtensions.contains(normalized) || imageExtensions.contains(normalized)
    }
}
