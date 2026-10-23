import XCTest
@testable import Whiteboard

final class ThemeTests: XCTestCase {
    func testSectionsGroupByDayThenMonth() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        func board(_ m: Int, _ d: Int, _ y: Int = 2026) -> Board {
            Board(created: cal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!, title: "\(y)-\(m)-\(d)", source: .scan)
        }
        let boards = [board(9, 3), board(10, 20), board(10, 2), board(10, 19), board(10, 20), board(12, 1, 2025), board(9, 28)]
        let s = BoardSection.group(boards, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Today", "Yesterday", "Earlier in October", "September", "December 2025"])
        XCTAssertEqual(s.map(\.boards.count), [2, 1, 1, 2, 1])
        XCTAssertEqual(s.map(\.compact), [false, false, true, true, true])
        XCTAssertEqual(s[3].boards.map(\.title), ["2026-9-28", "2026-9-3"], "newest first within a group")
    }

    func testPhotoCountText() {
        var b = Board(title: "x", source: .scan)
        b.photos = ["a", "b", "c"]
        XCTAssertEqual(b.photoCountText, "3 photos")
        b.leftOut = ["b"]
        XCTAssertEqual(b.photoCountText, "2 of 3 photos")
    }
}
