import XCTest
@testable import VolantCore

final class TimeCalculatorTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func answer(_ query: String) -> TimeCalculator.Result? {
        TimeCalculator.evaluate(query, now: now, localZone: paris, locale: Locale(identifier: "en_US"))
    }

    func testOwnerExampleAndImplicitLocalDestination() {
        XCTAssertTrue(answer("1pm EST in CET")?.text.hasPrefix("7:00 PM") == true)
        XCTAssertEqual(answer("1pm in EST"), answer("1pm EST"))
        XCTAssertEqual(answer("1pm EST")?.date, ISO8601DateFormatter().date(from: "2026-01-15T18:00:00Z"))
    }

    func testCitiesAndDaylightSaving() {
        XCTAssertTrue(answer("5pm ldn in sf")?.text.hasPrefix("9:00 AM") == true)
        XCTAssertTrue(answer("2026-03-15 3pm Los Angeles in Berlin")?.text.hasPrefix("11:00 PM") == true)
        XCTAssertTrue(answer("2026-07-15 1pm New York in Paris")?.text.hasPrefix("7:00 PM") == true)
        XCTAssertEqual(answer("2026-07-15 1pm EST in CET")?.text, "7:00 PM CEST · Jul 15, 2026")
        XCTAssertEqual(answer("2026-07-15 1pm EST in Paris")?.text, answer("2026-07-15 1pm New York in Paris")?.text)
        XCTAssertEqual(answer("2026-07-15 1pm EDT in CEST")?.text, answer("2026-07-15 1pm EST in CET")?.text)
    }

    func testRegionalAbbreviationsFollowTheRegionsSummerTime() {
        let october = ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z")!
        func summer(_ query: String) -> String? {
            TimeCalculator.evaluate(query, now: october, localZone: paris, locale: Locale(identifier: "en_US"))?.text
        }
        XCTAssertEqual(summer("4pm in CET"), "4:00 PM · your time")
        XCTAssertEqual(summer("4pm CET"), "4:00 PM · your time")
        XCTAssertEqual(summer("1pm EST in CET"), "7:00 PM CEST")
        XCTAssertEqual(summer("9am PST in EST"), "Noon EDT")
        XCTAssertEqual(summer("5pm BST in UTC"), "4:00 PM UTC")
        XCTAssertEqual(summer("4pm UTC in CET"), "6:00 PM CEST")
    }

    func testClockQueriesAndIANAIdentifiers() {
        XCTAssertTrue(answer("time in Tokyo")?.text.hasPrefix("9:00 PM") == true)
        XCTAssertEqual(answer("now in Dubai"), answer("time in Dubai"))
        XCTAssertEqual(answer("17:30 Europe/London to America/Los_Angeles")?.text, answer("5:30pm london in la")?.text)
        XCTAssertEqual(answer("17:30 Europe/London to America/Los_Angeles")?.date, answer("5:30pm london in sf")?.date)
        XCTAssertEqual(answer("  1 PM   EST in my time  ")?.text, answer("1pm EST")?.text)
    }

    func testRolloverAndHalfHourOffsets() {
        XCTAssertTrue(answer("2026-12-31 3pm PST in CET")?.text.contains("Jan 1, 2027") == true)
        XCTAssertTrue(answer("2026-01-01 1am Tokyo in sf")?.text.contains("Dec 31, 2025") == true)
        XCTAssertTrue(answer("time in Kolkata")?.text.contains("5:30 PM") == true)
        XCTAssertEqual(answer("time in Kolkata")?.text, "5:30 PM in Kolkata")
    }

    func testReadableAnswersAndRelativeDays() {
        XCTAssertEqual(answer("1pm EST in CET")?.text, "7:00 PM CET")
        XCTAssertEqual(answer("1pm EST")?.text, "7:00 PM · your time")
        XCTAssertEqual(answer("3pm PST in CET")?.text, "Midnight CET · tomorrow")
        XCTAssertEqual(answer("1am Tokyo in sf")?.text, "8:00 AM in San Francisco · yesterday")
        XCTAssertEqual(answer("11am UTC in CET")?.text, "Noon CET")
        XCTAssertEqual(answer("2026-07-15 1pm EST in Paris")?.text, "7:00 PM in Paris · Jul 15, 2026")
        XCTAssertEqual(answer("time in Tokyo")?.text, "9:00 PM in Tokyo")
    }

    func testRelativeDaysFollowTheUsersLocalDay() {
        let late = ISO8601DateFormatter().date(from: "2026-01-15T23:30:00Z")!
        let early = ISO8601DateFormatter().date(from: "2026-01-15T16:00:00Z")!
        XCTAssertEqual(TimeCalculator.evaluate("1pm EST", now: late, localZone: paris,
                                              locale: Locale(identifier: "en_US"))?.text,
                       "7:00 PM · your time · yesterday")
        XCTAssertEqual(TimeCalculator.evaluate("1am Tokyo in sf", now: early, localZone: paris,
                                              locale: Locale(identifier: "en_US"))?.text,
                       "8:00 AM in San Francisco")
    }

    private func friday(_ query: String) -> TimeCalculator.Result? {
        TimeCalculator.evaluate(query, now: ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z")!,
                                localZone: paris, locale: Locale(identifier: "en_US"))
    }

    func testDayWordsResolveALocalMomentWithoutAZone() throws {
        let evening = try XCTUnwrap(friday("7:30pm tomorrow"))
        XCTAssertEqual(evening.headline, "Tomorrow at 7:30 PM")
        XCTAssertEqual(evening.detail, "Saturday")
        XCTAssertEqual(evening.source, "Saturday, October 3")
        XCTAssertEqual(evening.text, "Saturday, October 3 at 7:30 PM")
        XCTAssertEqual(evening.date, ISO8601DateFormatter().date(from: "2026-10-03T17:30:00Z"))
        XCTAssertEqual(friday("tomorrow at 19:30"), evening)
        XCTAssertEqual(friday("Tomorrow   7:30 PM"), evening)
        XCTAssertEqual(friday("friday 3pm")?.headline, "Today at 3:00 PM")
        XCTAssertEqual(friday("tonight 9pm")?.detail, "Friday")
        XCTAssertEqual(friday("yesterday 10pm")?.headline, "Yesterday at 10:00 PM")
        let monday = try XCTUnwrap(friday("monday 9am"))
        XCTAssertEqual(monday.headline, "Monday at 9:00 AM")
        XCTAssertEqual(monday.detail, "In 3 days")
        XCTAssertEqual(monday.source, "Monday, October 5")
        XCTAssertEqual(friday("tomorrow 12pm")?.headline, "Tomorrow at noon")
    }

    func testNextAndThisWeekdayInTimeQueries() {
        XCTAssertEqual(friday("3pm next friday")?.headline, "Friday at 3:00 PM")
        XCTAssertEqual(friday("3pm next friday")?.detail, "In 7 days")
        XCTAssertEqual(friday("this friday 3pm")?.headline, "Today at 3:00 PM")
        XCTAssertEqual(friday("next monday 9am EST in CET")?.source, "Monday, October 5")
        XCTAssertNil(friday("next 3pm"))
    }

    func testSwapReversesConversionsExactly() throws {
        let sameDay = try XCTUnwrap(friday("1pm EST in CET"))
        XCTAssertEqual(sameDay.swap, "7:00pm cet in est")
        XCTAssertEqual(friday("7:00pm cet in est")?.text, "1:00 PM EDT")
        let nextDay = try XCTUnwrap(friday("10pm EST in CET"))
        XCTAssertEqual(nextDay.swap, "2026-10-03 4:00am cet in est")
        XCTAssertEqual(friday("2026-10-03 4:00am cet in est")?.text, "10:00 PM EDT · Oct 2, 2026")
        XCTAssertEqual(friday("1pm in EST")?.swap, "7:00pm local in est")
        XCTAssertEqual(friday("7:00pm local in est")?.text, "1:00 PM EDT")
        XCTAssertNil(friday("time in Tokyo")?.swap)
        XCTAssertNil(friday("7:30pm tomorrow")?.swap)
        XCTAssertNil(friday("diff Tokyo")?.swap)
    }

    func testTimeAfterElapsedDurationSomewhere() {
        XCTAssertEqual(friday("time in 4 hours in Tokyo")?.text, "10:00 PM in Tokyo")
        XCTAssertEqual(friday("time in 4 hours in Tokyo")?.source, "In 4 hours")
        XCTAssertEqual(friday("time in 90 minutes in New York")?.headline, "6:30 AM in New York")
        XCTAssertEqual(friday("time in 1 day in LA")?.text, "2:00 AM in Los Angeles · tomorrow")
        XCTAssertNil(friday("time in 4 parsecs in Tokyo"))
    }

    func testLastAndAfterNextWeekdays() {
        XCTAssertEqual(friday("3pm last friday")?.headline, "Friday at 3:00 PM")
        XCTAssertEqual(friday("3pm last friday")?.detail, "7 days ago")
        XCTAssertEqual(friday("last thursday 9am")?.headline, "Yesterday at 9:00 AM")
        XCTAssertEqual(friday("friday after next 3pm")?.detail, "In 14 days")
    }

    func testDayWordsCombineWithZonesInAnyPosition() throws {
        let meeting = try XCTUnwrap(friday("tomorrow 9am EST in CET"))
        XCTAssertEqual(meeting.text, "3:00 PM CEST · tomorrow")
        XCTAssertEqual(meeting.source, "Saturday, October 3")
        XCTAssertEqual(friday("9am EST tomorrow in CET"), meeting)
        XCTAssertEqual(friday("tomorrow at 9am EST in CET"), meeting)
        XCTAssertEqual(friday("7:30pm tomorrow in Tokyo")?.text, "12:30 PM · your time · tomorrow")
    }

    func testIANACityNamesWorkWithoutTheirRegion() {
        XCTAssertEqual(friday("3pm lisbon in tokyo")?.text, "11:00 PM in Tokyo")
        XCTAssertEqual(friday("time in buenos aires")?.headline.hasSuffix("in Buenos Aires"), true)
        XCTAssertEqual(friday("3pm Europe/Lisbon in Tokyo")?.text, friday("3pm lisbon in tokyo")?.text)
    }

    func testDayWordsNeverTurnPlainTextIntoAnAnswer() {
        for query in ["tomorrow", "monday", "1pm", "7 tomorrow", "tomorrow 25:00", "7pm tomorrow yesterday",
                      "2026-10-05 9am tomorrow", "time in tokyo tomorrow", "tomorrow 9am CST"] {
            XCTAssertNil(friday(query), query)
        }
    }

    func testTimeDifferenceFromTheOwnersClock() throws {
        let tokyo = try XCTUnwrap(friday("time diff Tokyo"))
        XCTAssertEqual(tokyo.headline, "7 hours ahead")
        XCTAssertEqual(tokyo.text, "Tokyo is 7 hours ahead")
        XCTAssertEqual(tokyo.detail, "6:00 PM in Tokyo")
        XCTAssertEqual(tokyo.source, "Now")
        XCTAssertEqual(friday("diff New York")?.text, "New York is 6 hours behind")
        XCTAssertEqual(friday("time difference with Kolkata")?.headline, "3 hours 30 minutes ahead")
        XCTAssertEqual(friday("diff to berlin")?.headline, "Same time")
        XCTAssertEqual(friday("diff Berlin")?.text, "Berlin is on your time")
        XCTAssertEqual(friday("diff EST")?.text, "EDT is 6 hours behind")
        XCTAssertEqual(friday("diff EST")?.detail, "5:00 AM EDT")
        XCTAssertEqual(friday("diff Adelaide")?.headline, "7 hours 30 minutes ahead")
        XCTAssertNil(friday("diff"))
        XCTAssertNil(friday("diff Atlantis"))
        XCTAssertNil(friday("diff tokyo tomorrow"))
    }

    func testRejectsMalformedAmbiguousAndDSTTimes() {
        for query in ["Safari", "1pm", "1pm EST in", "1pm CST in CET", "1pm IST", "1pm France",
                      "25:00 EST", "0pm EST", "13pm EST", "1:60pm EST", "1 EST", "1pm EST garbage",
                      "2026-02-30 1pm EST", "2026-03-08 2:30am New York in Paris",
                      "2026-11-01 1:30am New York in Paris", "1pm EST in CET in Tokyo"] {
            XCTAssertNil(answer(query), query)
        }
        XCTAssertNil(answer(String(repeating: "1", count: 257)))
    }

    func testNicknamesLabelTheCityTheOwnerTyped() {
        XCTAssertEqual(answer("5pm ldn in sf")?.headline, "9:00 AM in San Francisco")
        XCTAssertEqual(answer("5pm ldn in sf")?.date, answer("5pm London in Los Angeles")?.date)
        XCTAssertEqual(answer("5pm london in la")?.headline, "9:00 AM in Los Angeles")
        XCTAssertEqual(answer("9am nyc in mumbai")?.headline, "7:30 PM in Mumbai")
        XCTAssertEqual(answer("time diff sf")?.detail, "4:00 AM in San Francisco")
        XCTAssertEqual(friday("time in 4 hours in San Francisco")?.headline, "6:00 AM in San Francisco")
    }

    func testTimeAfterElapsedDurationHere() {
        XCTAssertEqual(friday("time in 4 hours")?.headline, "3:00 PM")
        XCTAssertEqual(friday("time in 4 hours")?.detail, "Your time · Today")
        XCTAssertEqual(friday("time in 4 hours")?.source, "In 4 hours")
        XCTAssertEqual(friday("time in 90 minutes")?.headline, "12:30 PM")
        XCTAssertEqual(friday("time in 4 hours in Tokyo")?.text, "10:00 PM in Tokyo")
        XCTAssertNil(friday("time in 4 parsecs"))
    }

    private func suggestions(_ query: String) -> [String] {
        TimeCalculator.suggestions(query, now: now, localZone: paris, locale: Locale(identifier: "en_US")).map { "\($0.query) = \($0.result.headline)" }
    }

    func testAmbiguousAbbreviationsOfferEveryRegion() {
        XCTAssertNil(answer("5pm pst in ist"))
        XCTAssertEqual(suggestions("5pm pst in ist"), ["5pm pst in IST (India) = 6:30 AM IST (India)",
                                                       "5pm pst in IST (Ireland) = 1:00 AM GMT (Ireland)",
                                                       "5pm pst in IST (Israel) = 3:00 AM IST (Israel)"])
        XCTAssertEqual(suggestions("9am cst in london"), ["9am CST (US) in london = 3:00 PM in London",
                                                          "9am CST (China) in london = 1:00 AM in London"])
        XCTAssertEqual(suggestions("time in ast").count, 2)
        XCTAssertEqual(answer("10am ist (india) in utc")?.headline, "4:30 AM UTC")
        XCTAssertEqual(answer("10am IST India in utc")?.headline, "4:30 AM UTC")
        XCTAssertEqual(answer("5pm bst in pst")?.headline, "9:00 AM PST", "BST stays British Summer Time")
        XCTAssertEqual(suggestions("5pm pst in tokyo"), [])
    }

    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testSkippedWallTimeOffersTheNearestValidTime() throws {
        let newYork = try XCTUnwrap(TimeCalculator.suggestions("2026-03-08 2:30am New York in Paris", now: now, localZone: paris,
                                                               locale: Locale(identifier: "en_US")).first)
        XCTAssertEqual(newYork.query, "2026-03-08 3:00am New York in Paris")
        XCTAssertEqual(newYork.result.date, instant("2026-03-08T07:00:00Z"))
        XCTAssertEqual(newYork.result.headline, "8:00 AM in Paris")
        XCTAssertEqual(newYork.result.source, "2:30 AM is skipped · clocks jump to 3:00 AM")
        XCTAssertEqual(suggestions("2026-03-08 2:30am New York in Paris").count, 1)
        XCTAssertEqual(answer(newYork.query)?.date, newYork.result.date, "The offered query answers on its own")

        XCTAssertEqual(suggestions("2026-03-29 02:30 Berlin in New York"), ["2026-03-29 03:00 Berlin in New York = 9:00 PM in New York"])
        XCTAssertEqual(answer("2026-03-29 03:00 Berlin in New York")?.date, instant("2026-03-29T01:00:00Z"))
        XCTAssertEqual(answer("2026-03-28 2:30am Berlin in UTC")?.date, instant("2026-03-28T01:30:00Z"), "The day before keeps winter time")
        XCTAssertEqual(answer("2026-03-30 2:30am Berlin in UTC")?.date, instant("2026-03-30T00:30:00Z"), "The day after is on summer time")
        XCTAssertEqual(answer("2026-03-07 2:30am New York in UTC")?.date, instant("2026-03-07T07:30:00Z"))
        XCTAssertEqual(answer("2026-03-09 2:30am New York in UTC")?.date, instant("2026-03-09T06:30:00Z"))
    }

    func testRepeatedWallTimeOffersBothReadings() {
        XCTAssertNil(answer("2026-11-01 1:30am New York in Paris"))
        XCTAssertEqual(suggestions("2026-11-01 1:30am New York in Paris"),
                       ["2026-11-01 1:30am (EDT) New York in Paris = 6:30 AM in Paris",
                        "2026-11-01 1:30am (EST) New York in Paris = 7:30 AM in Paris"])
        XCTAssertEqual(suggestions("2026-11-01 1:30 am EST in CET"),
                       ["2026-11-01 1:30 am (EDT) EST in CET = 6:30 AM CET", "2026-11-01 1:30 am (EST) EST in CET = 7:30 AM CET"])
        XCTAssertEqual(suggestions("2026-10-25 2:30am Berlin in UTC"),
                       ["2026-10-25 2:30am (CEST) Berlin in UTC = 12:30 AM UTC", "2026-10-25 2:30am (CET) Berlin in UTC = 1:30 AM UTC"])
        XCTAssertEqual(suggestions("2026-10-25 02:30 Paris in UTC"),
                       ["2026-10-25 02:30 (daylight) Paris in UTC = 12:30 AM UTC", "2026-10-25 02:30 (standard) Paris in UTC = 1:30 AM UTC"])
        XCTAssertEqual(answer("2026-11-01 1:30am (est) New York in Paris")?.date, instant("2026-11-01T06:30:00Z"))
        XCTAssertEqual(answer("2026-11-01 1:30am (EDT) New York in Paris")?.date, instant("2026-11-01T05:30:00Z"))
        XCTAssertEqual(answer("2026-10-24 2:30am Berlin in UTC")?.date, instant("2026-10-24T00:30:00Z"), "The day before is on summer time")
        XCTAssertEqual(answer("2026-10-26 2:30am Berlin in UTC")?.date, instant("2026-10-26T01:30:00Z"), "The day after is on winter time")
        XCTAssertEqual(answer("2026-10-31 1:30am New York in UTC")?.date, instant("2026-10-31T05:30:00Z"))
        XCTAssertEqual(answer("2026-11-02 1:30am New York in UTC")?.date, instant("2026-11-02T06:30:00Z"))
    }

    func testReadingMustMatchTheClockInEffect() {
        XCTAssertEqual(answer("2026-07-01 1:30am (EDT) New York in UTC")?.date, instant("2026-07-01T05:30:00Z"))
        for query in ["2026-07-01 1:30am (EST) New York in UTC", "2026-11-01 1:30am (CET) New York in UTC",
                      "2026-11-01 1:30am (later) New York in UTC", "2026-03-08 2:30am (EDT) New York in UTC",
                      "time in (EDT) New York"] {
            XCTAssertNil(answer(query), query)
            XCTAssertEqual(suggestions(query), [], query)
        }
    }

    func testTransitionDaysWithAnInjectedClockAndLocalZone() {
        let newYork = TimeZone(identifier: "America/New_York")!
        func around(_ query: String, _ now: String) -> [String] {
            TimeCalculator.suggestions(query, now: instant(now), localZone: newYork, locale: Locale(identifier: "en_US"))
                .map { "\($0.query) = \($0.result.headline) · \($0.result.source)" }
        }
        XCTAssertEqual(around("tomorrow 1:30am", "2026-10-31T16:00:00Z"),
                       ["tomorrow 1:30am (EDT) local = Tomorrow at 1:30 AM · Sunday, November 1",
                        "tomorrow 1:30am (EST) local = Tomorrow at 1:30 AM · Sunday, November 1"])
        XCTAssertEqual(around("1:30am tomorrow", "2026-10-31T16:00:00Z"),
                       ["1:30am (EDT) tomorrow = Tomorrow at 1:30 AM · Sunday, November 1",
                        "1:30am (EST) tomorrow = Tomorrow at 1:30 AM · Sunday, November 1"])
        XCTAssertEqual(around("tomorrow 2:30am", "2026-03-07T16:00:00Z"),
                       ["tomorrow 3:00am = Tomorrow at 3:00 AM · 2:30 AM is skipped · clocks jump to 3:00 AM"])
        XCTAssertEqual(around("1:30am local in London", "2026-11-01T12:00:00Z"),
                       ["1:30am (EDT) local in London = 5:30 AM in London · Sunday, November 1",
                        "1:30am (EST) local in London = 6:30 AM in London · Sunday, November 1"])
        XCTAssertEqual(around("1:30am local in London", "2026-11-02T12:00:00Z").count, 0, "The next day has one reading and answers directly")
        XCTAssertNotNil(TimeCalculator.evaluate("1:30am local in London", now: instant("2026-11-02T12:00:00Z"), localZone: newYork,
                                                locale: Locale(identifier: "en_US")))
    }

    func testIncompleteQueriesNeverExplainTransitions() {
        for query in ["2026-03-08 2:30am New York in", "2026-03-08 2:30am New York to", "2026-03-08 2:30am",
                      "2026-11-01 1:30am (", "2026-11-01 1:30am (ED", "2026-11-01 1:30am New York in Par"] {
            XCTAssertEqual(suggestions(query), [], query)
        }
    }

    func testAmbiguousAbbreviationsExplainTransitionsPerRegion() {
        XCTAssertEqual(suggestions("2026-03-08 2:30am cst in utc"),
                       ["2026-03-08 3:00am CST (US) in utc = 8:00 AM UTC", "2026-03-08 2:30am CST (China) in utc = 6:30 PM UTC"])
    }

    func testCalculatorCardsCarryEachReading() {
        let cards = CalculationAnswer.answers(for: "2026-11-01 1:30am New York in Paris", now: now, localZone: paris,
                                              locale: Locale(identifier: "en_US"))
        XCTAssertEqual(cards.map(\.input), ["2026-11-01 1:30am (EDT) New York in Paris", "2026-11-01 1:30am (EST) New York in Paris"])
        XCTAssertEqual(cards.map(\.copyText), ["6:30 AM in Paris · Nov 1, 2026", "7:30 AM in Paris · Nov 1, 2026"])
        let skipped = CalculationAnswer.answers(for: "2026-03-08 2:30am New York in Paris", now: now, localZone: paris,
                                                locale: Locale(identifier: "en_US"))
        XCTAssertEqual(skipped.map(\.inputDetail), ["2:30 AM is skipped · clocks jump to 3:00 AM"])
    }

    func testParenthesizedZoneWithoutAFollowingSourceStaysTheSourceZone() {
        XCTAssertNotNil(answer("1pm (est)"))
        for (written, plain) in [("1pm (est)", "1pm est"), ("1pm (est) in CET", "1pm est in CET"), ("1pm (EST) to CET", "1pm EST to CET")] {
            XCTAssertEqual(answer(written)?.date, answer(plain)?.date, written)
            XCTAssertEqual(answer(written)?.text, answer(plain)?.text, written)
            XCTAssertEqual(answer(written)?.source, answer(plain)?.source, written)
        }
        XCTAssertEqual(answer("2026-07-15 1pm (est) in CET")?.text, "7:00 PM CEST · Jul 15, 2026")
        XCTAssertEqual(answer("2026-11-01 1:30am (EST) New York in Paris")?.date, instant("2026-11-01T06:30:00Z"),
                       "Followed by a source zone, the parenthesized word selects a reading")
        XCTAssertEqual(suggestions("2026-11-01 1:30am in New York in Paris"),
                       ["2026-11-01 1:30am (EDT) New York in Paris = 6:30 AM in Paris",
                        "2026-11-01 1:30am (EST) New York in Paris = 7:30 AM in Paris"])
    }

    func testAmbiguousAbbreviationOnARepeatedTimeOffersAtMostThreeCards() {
        XCTAssertEqual(suggestions("2026-11-01 1:30am cst in utc"),
                       ["2026-11-01 1:30am (CDT) CST (US) in utc = 6:30 AM UTC",
                        "2026-11-01 1:30am (CST) CST (US) in utc = 7:30 AM UTC",
                        "2026-11-01 1:30am CST (China) in utc = 5:30 PM UTC"])
        let irish = suggestions("2026-10-25 1:30am ist in utc")
        XCTAssertEqual(irish.count, 3, irish.joined(separator: "\n"))
        XCTAssertEqual(irish.first, "2026-10-25 1:30am IST (India) in utc = 8:00 PM UTC")
    }
}
