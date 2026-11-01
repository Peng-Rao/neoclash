import Foundation
import NeoClashMobileCore

enum RuntimeFiles {
    private static let geodataFiles = ["country.mmdb", "geosite.dat"]

    /// The generated config holds node credentials and the controller secret.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try AtomicFileWriter.write(data, to: url)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// Copies the bundled geodata next to the runtime config, where the core looks for it. The
    /// packet tunnel cannot read the app bundle, so this has to happen before every start.
    static func installGeodata(into directory: URL) throws {
        let fileManager = FileManager.default
        for name in geodataFiles {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw RuntimeFilesError.missingGeodata(name)
            }
            let destination = directory.appendingPathComponent(name)
            if fileSize(of: destination) == fileSize(of: source) {
                continue
            }
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

enum RuntimeFilesError: Error, LocalizedError {
    case missingGeodata(String)

    var errorDescription: String? {
        switch self {
        case .missingGeodata(let name):
            "This build is missing \(name)."
        }
    }
}
