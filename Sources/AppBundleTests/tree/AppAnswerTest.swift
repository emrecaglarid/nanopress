@testable import AppBundle
import XCTest

/// An app that doesn't answer mustn't hold up a refresh. See answerWithin
@MainActor
final class AppAnswerTest: XCTestCase {
    func testAnAnswerInTimeIsUsed() async {
        let answer = await answerWithin(.seconds(1)) { [1, 2] }
        XCTAssertEqual(answer, .windows([1, 2]))
    }

    func testAnAppThatDoesntAnswerIsLeftBehindOnTime() async {
        let start = ContinuousClock.now
        let answer = await answerWithin(.milliseconds(100)) {
            try await Task.sleep(for: .seconds(30)) // Stands in for an app that never answers
            return [1]
        }
        XCTAssertEqual(answer, .tooSlow)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testAFailureIsNotTakenForSlowness() async {
        struct Failure: Error {}
        let answer = await answerWithin(.seconds(1)) { throw Failure() }
        XCTAssertEqual(answer, .failed)
    }
}
