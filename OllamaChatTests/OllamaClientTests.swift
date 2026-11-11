import XCTest
@testable import OllamaChat

final class OllamaClientTests: XCTestCase {
    func testStreamChunkWithThinking() throws {
        let data = Data(#"{"message":{"content":"Hello","thinking":"Consider"},"done":false}"#.utf8)
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
        XCTAssertEqual(chunk.message?.content, "Hello")
        XCTAssertEqual(chunk.message?.thinking, "Consider")
        XCTAssertEqual(chunk.done, false)
    }
    func testRejectInvalidEndpoints() {
        for value in ["localhost", "file:///tmp/test", "ftp://localhost/api/chat"] {
            XCTAssertThrowsError(try OllamaClient.endpoint(value))
        }
    }
    func testChatMessageRoundTripDoesNotSendID() throws {
        let message = ChatMessage(role: "user", content: "Hello")
        let data = try JSONEncoder().encode(message)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("id"))
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data).content, "Hello")
    }
}
