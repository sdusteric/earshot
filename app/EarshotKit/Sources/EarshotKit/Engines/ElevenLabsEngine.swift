import Foundation

/// ElevenLabs text to speech, the same request speak.sh makes.
public struct ElevenLabsEngine: SpeechEngine {
    let key: String, voice: String, model: String
    let session: URLSession

    public init(key: String, voice: String, model: String, session: URLSession = .shared) {
        self.key = key; self.voice = voice; self.model = model; self.session = session
    }

    public var name: String { "elevenlabs" }
    public var fileExtension: String { "mp3" }
    public func cacheKey(_ text: String) -> String { "\(model) \(voice) \(text)" }

    public func render(_ text: String, to url: URL) async throws {
        guard let endpoint = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["text": text, "model_id": model])
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        try data.write(to: url)
    }
}
