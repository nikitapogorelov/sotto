import Foundation

/// The Whisper model presets Sotto knows how to download. All multilingual —
/// mixed-language calls (e.g. Russian + English) are the primary use case,
/// so the English-only variants are deliberately excluded.
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case largeV3Turbo = "large-v3-turbo"
    case small
    case base

    var id: String { rawValue }

    /// Highest quality first — used to pick a fallback when the selected
    /// model isn't installed.
    static let preferenceOrder: [WhisperModel] = [.largeV3Turbo, .small, .base]

    var displayName: String { rawValue }

    var fileName: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var approximateBytes: Int64 {
        switch self {
        case .largeV3Turbo: return 1_620_000_000
        case .small: return 488_000_000
        case .base: return 148_000_000
        }
    }

    var sizeLabel: String {
        switch self {
        case .largeV3Turbo: return "1.6 GB"
        case .small: return "466 MB"
        case .base: return "142 MB"
        }
    }

    var qualityBlurb: String {
        switch self {
        case .largeV3Turbo: return "Best quality, handles mixed-language calls"
        case .small: return "Good balance of speed and accuracy"
        case .base: return "Fastest, rougher on accents and crosstalk"
        }
    }

    /// Which known models are present in a Models directory listing.
    /// Unknown files (e.g. hand-dropped ggml models) are ignored.
    static func installedModels(fileNames: [String]) -> Set<WhisperModel> {
        Set(allCases.filter { fileNames.contains($0.fileName) })
    }

    /// Best-quality installed model, or nil when none are.
    static func bestInstalled(from installed: Set<WhisperModel>) -> WhisperModel? {
        preferenceOrder.first { installed.contains($0) }
    }
}
