import Testing
@testable import Sotto

struct WhisperModelTests {
    @Test func fileNamesFollowGGMLConvention() {
        #expect(WhisperModel.largeV3Turbo.fileName == "ggml-large-v3-turbo.bin")
        #expect(WhisperModel.small.fileName == "ggml-small.bin")
        #expect(WhisperModel.base.fileName == "ggml-base.bin")
    }

    @Test func downloadURLsPointAtHuggingFace() {
        for model in WhisperModel.allCases {
            let url = model.downloadURL.absoluteString
            #expect(url == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.fileName)")
        }
    }

    @Test func installedModelsMatchesKnownFileNamesOnly() {
        let names = [
            "ggml-base.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-tiny.bin",          // known ggml model, not a Sotto preset
            "notes.txt",
            ".DS_Store",
        ]
        #expect(WhisperModel.installedModels(fileNames: names) == [.base, .largeV3Turbo])
        #expect(WhisperModel.installedModels(fileNames: []) == [])
    }

    @Test func bestInstalledPrefersQuality() {
        #expect(WhisperModel.bestInstalled(from: [.base, .small, .largeV3Turbo]) == .largeV3Turbo)
        #expect(WhisperModel.bestInstalled(from: [.base, .small]) == .small)
        #expect(WhisperModel.bestInstalled(from: [.base]) == .base)
        #expect(WhisperModel.bestInstalled(from: []) == nil)
    }

    /// Raw values are persisted in UserDefaults — they must stay stable.
    @Test func rawValueRoundTrip() {
        for model in WhisperModel.allCases {
            #expect(WhisperModel(rawValue: model.rawValue) == model)
        }
        #expect(WhisperModel(rawValue: "large-v3-turbo") == .largeV3Turbo)
    }
}
