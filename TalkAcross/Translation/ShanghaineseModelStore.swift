import CryptoKit
import Foundation

actor ShanghaineseModelStore {
    enum Status {
        case missing, downloading, ready
    }

    static let shared = ShanghaineseModelStore()
    private static let downloadURL = URL(string: "https://huggingface.co/spycsh/shanghainese-opus-sh-zh-3500/resolve/bc92f9ced6711e07c9c91aa7dd71b27f8da0eb9c/model.safetensors")!
    private static let fileSize = 309_965_092
    private static let sha256 = "d6e474056c480f67d8c76d3e3c2fb62e65e7b492a7fdbd45c0a4585811e96138"

    private let folder: URL
    private let tokenizerURL: URL?
    private var tokenizer: ShanghaineseTokenizer?
    private var isDownloading = false
    private let downloadProgress = DownloadProgress()

    init(
        folder: URL = URL.applicationSupportDirectory.appendingPathComponent("Shanghainese", isDirectory: true),
        tokenizerURL: URL? = Bundle.main.url(forResource: "ShanghaiTokenizer", withExtension: "json")
    ) {
        self.folder = folder
        self.tokenizerURL = tokenizerURL
    }

    private var localFile: URL { folder.appendingPathComponent("model.safetensors") }

    var status: Status {
        if isDownloading { return .downloading }
        let size = try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return size == Self.fileSize ? .ready : .missing
    }

    /// Fraction of the pack downloaded so far, or nil when no download is running.
    var downloadFraction: Double? { isDownloading ? downloadProgress.fraction : nil }

    func requirePack() throws {
        guard status == .ready else { throw ShanghaineseNormalizationIssue.modelMissing }
    }

    func download() async throws {
        guard status == .missing else { return }
        isDownloading = true
        downloadProgress.update(0)
        defer { isDownloading = false }

        let downloader = FileDownloader(expectedBytes: Int64(Self.fileSize), progress: downloadProgress)
        let (temporaryFile, response) = try await downloader.download(from: Self.downloadURL)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              try temporaryFile.resourceValues(forKeys: [.fileSizeKey]).fileSize == Self.fileSize else {
            throw ShanghaineseNormalizationIssue.invalidPack
        }
        try Self.verifyChecksum(of: temporaryFile)
        try Task.checkCancellation()

        var directory = folder
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if FileManager.default.fileExists(atPath: localFile.path) {
            _ = try FileManager.default.replaceItemAt(localFile, withItemAt: temporaryFile)
        } else {
            try FileManager.default.moveItem(at: temporaryFile, to: localFile)
        }
    }

    func remove() throws {
        guard status == .ready else { return }
        try FileManager.default.removeItem(at: localFile)
        tokenizer = nil
    }

    func normalize(_ text: String) throws -> String {
        try requirePack()
        try Task.checkCancellation()
        guard let tokenizerURL else { throw ShanghaineseNormalizationIssue.invalidPack }

        let tokenizer = try tokenizer ?? ShanghaineseTokenizer(contentsOf: tokenizerURL)
        self.tokenizer = tokenizer
        let input = try tokenizer.encode(text)
        guard !input.isEmpty else { throw ShanghaineseNormalizationIssue.noConversion }
        let model = try ShanghaineseMarian(contentsOf: localFile)
        let output = tokenizer.decode(try model.generate(from: input))
        guard output.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            throw ShanghaineseNormalizationIssue.noConversion
        }
        return output
    }

    private static func verifyChecksum(of file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
        guard digest == sha256 else { throw ShanghaineseNormalizationIssue.invalidPack }
    }
}

nonisolated enum ShanghaineseNormalizationIssue: LocalizedError {
    case modelMissing, invalidPack, textTooLong, noConversion

    var errorDescription: String? {
        switch self {
        case .modelMissing: String(localized: "error.shanghainese.pack_missing")
        case .invalidPack: String(localized: "error.shanghainese.invalid_pack")
        case .textTooLong: String(localized: "error.shanghainese.text_too_long")
        case .noConversion: String(localized: "error.shanghainese.conversion_failed")
        }
    }
}
