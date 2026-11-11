import Foundation

struct ChatMessage: Codable, Identifiable, Sendable {
    var id = UUID()
    let role: String
    var content: String
    var thinking: String? = nil

    enum CodingKeys: String, CodingKey { case role, content, thinking }
}

struct StreamChunk: Decodable {
    struct Message: Decodable { let content: String?; let thinking: String? }
    let message: Message?
    let done: Bool?
    let error: String?
}

enum OllamaError: LocalizedError {
    case invalidURL, server(String), incomplete
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS chat endpoint."
        case .server(let message): message
        case .incomplete: "The response ended unexpectedly. You can try again."
        }
    }
}

struct OllamaClient: Sendable {
    static func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme),
              url.host != nil else { throw OllamaError.invalidURL }
        return url
    }

    func models(endpoint: String) async throws -> [String] {
        let chat = try Self.endpoint(endpoint)
        let url = chat.deletingLastPathComponent().appendingPathComponent("tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: String(decoding: data, as: UTF8.self))
        struct List: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        return try JSONDecoder().decode(List.self, from: data).models.map(\.name).sorted()
    }

    static func validate(_ response: URLResponse, body: String) throws {
        guard let http = response as? HTTPURLResponse else { throw OllamaError.server("Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.server("Ollama returned HTTP \(http.statusCode): \(body.prefix(400))")
        }
    }

    func stream(endpoint: String, model: String, messages: [ChatMessage],
                receive: @MainActor (StreamChunk) -> Void) async throws {
        struct Payload: Encodable { let model: String; let messages: [ChatMessage]; let stream = true }
        var request = URLRequest(url: try Self.endpoint(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(Payload(model: model, messages: messages))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            try Self.validate(response, body: body)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(line.utf8))
            if let error = chunk.error { throw OllamaError.server(error) }
            await receive(chunk)
            if chunk.done == true { return }
        }
        throw OllamaError.incomplete
    }
}
