import Testing
@testable import PrismCalculator

// Ported from apps/desktop/src/providers/datetime.test.ts.

@Test(arguments: [
    ("2026-09-06 + 3 days", "2026-09-09"),
    ("2026-09-06 - 7 days", "2026-08-30"),
    ("2026-12-31 + 1 day", "2027-01-01"),
    ("2024-02-28 + 1 day", "2024-02-29"),
    ("2000-02-28 + 2 days", "2000-03-01"),
    ("1900-02-28 + 1 day", "1900-03-01"),
    ("0099-12-31 + 1 day", "0100-01-01"),
    ("0001-01-01 + 0 days", "0001-01-01"),
    ("1582-10-04 + 1 day", "1582-10-05"),
    ("2026-09-06 + 3일", "2026-09-09"),
    ("2026-09-06 3일 후", "2026-09-09"),
    ("2026년 9월 6일에서 3일 전", "2026-09-03"),
    ("2026년9월6일 3일 뒤", "2026-09-09"),
    ("2026-09-09 - 2026-09-06", "3 days"),
    ("2026-09-06 - 2026-09-09", "-3 days"),
    ("2026-09-06 to 2026-09-09", "3 days"),
    ("2026-09-06 to 2026-09-06", "0 days"),
    ("2026-09-06부터 2026-09-09까지", "3 days"),
    ("2026년 9월 6일과 2026년 9월 9일 차이", "3 days"),
    ("2024-02-28 ~ 2024-03-01", "2 days"),
    ("2026-03-07 to 2026-03-09", "2 days"),
])
func calculatesDates(query: String, expected: String) throws {
    #expect(try DateTimeCalculation.calculate(query)?.result == expected)
}

@Test(arguments: [
    ("2026-09-06 09:00 Asia/Seoul to UTC", "2026-09-06T00:00:00Z"),
    ("2026년 9월 6일 09:00 서울 to UTC", "2026-09-06T00:00:00Z"),
    ("2026년 9월 6일 09:00 서울에서 UTC로", "2026-09-06T00:00:00Z"),
    ("2026-09-06 09:00 Asia/Seoul에서 UTC로", "2026-09-06T00:00:00Z"),
    ("2026-09-06 00:00 Asia/Seoul to UTC", "2026-09-05T15:00:00Z"),
    ("2026-09-06T09:00:12+09:00 to UTC", "2026-09-06T00:00:12Z"),
    ("2026-09-06T00:00Z to Asia/Seoul", "2026-09-06T09:00:00+09:00[Asia/Seoul]"),
    ("2026-09-06 09:00 Asia/Kathmandu to UTC", "2026-09-06T03:15:00Z"),
    ("2026-09-06 09:00 Asia/Seoul to America/New_York", "2026-09-05T20:00:00-04:00[America/New_York]"),
    ("2026-03-08 01:59 America/New_York to UTC", "2026-03-08T06:59:00Z"),
    ("2026-03-08 03:00 America/New_York to UTC", "2026-03-08T07:00:00Z"),
    ("2026-11-01T01:30-04:00 America/New_York to UTC", "2026-11-01T05:30:00Z"),
    ("2026-11-01T01:30-05:00 America/New_York to UTC", "2026-11-01T06:30:00Z"),
    ("2026-11-01T05:30Z to America/New_York", "2026-11-01T01:30:00-04:00[America/New_York]"),
    ("2026-11-01T06:30Z to America/New_York", "2026-11-01T01:30:00-05:00[America/New_York]"),
    ("2026-04-05T01:45+10:30 Australia/Lord_Howe to UTC", "2026-04-04T15:15:00Z"),
    ("2026-09-06 09:00 asia/seoul to utc", "2026-09-06T00:00:00Z"),
])
func convertsTimeZonesToExactCopyableTimes(query: String, expected: String) throws {
    #expect(try DateTimeCalculation.calculate(query)?.result == expected)
}

@Test(arguments: [
    ("2026-02-29 + 1 day", "Invalid calendar date"),
    ("1900-02-29 + 1 day", "Invalid calendar date"),
    ("2026-04-31 to 2026-05-01", "Invalid calendar date"),
    ("2026-00-01 + 1 day", "Invalid calendar date"),
    ("0000-01-01 + 1 day", "Invalid calendar date"),
    ("9999-12-31 + 1 day", "between years"),
    ("0001-01-01 - 1 day", "between years"),
    ("2026-09-06 + 999999999999999999 days", "whole days"),
    ("2026-09-06 24:00 UTC to Asia/Seoul", "Invalid time"),
    ("2026-09-06 09:60 Asia/Seoul to UTC", "Invalid time"),
    ("2026-09-06T09:00:60Z to UTC", "leap seconds"),
    ("2026-09-06T09:00+24:00 to UTC", "Invalid UTC offset"),
    ("2026-09-06T09:00+00:60 to UTC", "Invalid UTC offset"),
    ("2026-09-06 09:00 CST to UTC", "IANA time zone"),
    ("2026-09-06 09:00 Missing/Zone to UTC", "Unknown time zone"),
    ("2026-09-06 09:00 UTC to Missing/Zone", "Unknown time zone"),
    ("2026-11-01 01:30 America/New_York to UTC", "occurs twice"),
    ("2026-03-08 02:30 America/New_York to UTC", "does not exist"),
    ("2026-04-05 01:45 Australia/Lord_Howe to UTC", "occurs twice"),
    ("2026-10-04 02:15 Australia/Lord_Howe to UTC", "does not exist"),
    ("2011-12-30 12:00 Pacific/Apia to UTC", "does not exist"),
    ("2026-03-08T02:30-05:00 America/New_York to UTC", "does not match"),
    ("2026-09-06T09:00+08:00 Asia/Seoul to UTC", "does not match"),
    ("2026-09-06T09:00+01:00 UTC to Asia/Seoul", "does not match"),
    ("1900-01-01 09:00 Asia/Seoul to UTC", "before 1973"),
    ("0001-01-01T00:00Z to America/New_York", "between years"),
    ("9999-12-31T23:00Z to Asia/Seoul", "between years"),
])
func explainsInvalidOrAmbiguousInput(query: String, message: String) {
    do {
        let result = try DateTimeCalculation.calculate(query)
        Issue.record("Expected \(message), got \(String(describing: result))")
    } catch {
        #expect(error.message.contains(message), "\(error.message)")
    }
}

@Test(arguments: [
    "calendar", "2026-09-06", "today + 3 days", "오늘 3일 후", "09/06/2026 + 3 days",
    "2026-09-06 + 1 month", "2026-09-06 + 1.5 days", "2026-09-06 + -3 days",
    "2026-09-06 09:00 to UTC", "2026-09-06 09:00 Asia/Seoul to", "1 h to min",
    "2026-09-06 + 3 days\n", "2026-09-06\t+ 3 days", String(repeating: "x", count: 257),
])
func leavesUnsupportedOrIncompleteQueriesUnanswered(query: String) throws {
    #expect(try DateTimeCalculation.calculate(query) == nil)
}

@Test func correlatesAnswersAndCopiesTheExactDisplay() throws {
    let query = " 2026-09-06 09:00 Asia/Seoul to UTC "
    let answer = try #require(InstantAnswers.dateTime(query))
    #expect(answer.title == "2026-09-06T00:00:00Z")
    #expect(answer.copyValue == answer.title)
    #expect(answer.subtitle.isEmpty)
    #expect(answer.accessory == "Asia/Seoul → UTC")
    #expect(answer.matchedQuery == "2026-09-06 09:00 Asia/Seoul to UTC")
    #expect(answer.kind == .timeZone)
    #expect(InstantAnswers.dateTime("2026-09-06 +") == nil)
    #expect(InstantAnswers.dateTime("2026-02-29 + 1 day")?.kind == .failure)
}
