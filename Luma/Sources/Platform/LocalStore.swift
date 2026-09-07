import Foundation

@MainActor
final class LocalStore {
    private let url: URL
    init() throws {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Luma", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        url = directory.appendingPathComponent("state.json")
    }
    func load() throws -> AppArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppArchive() }
        let archive = try JSONDecoder().decode(AppArchive.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1 else { throw AppError.message("Эта версия данных требует обновления Luma.") }
        return archive
    }
    func save(_ archive: AppArchive) throws {
        let data = try JSONEncoder().encode(archive)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
