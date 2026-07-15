import Foundation

private let addedDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM d, yyyy"
    f.timeZone = TimeZone(abbreviation: "UTC")
    return f
}()

func parseDateFormat(timestamp: TimeInterval) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    return addedDateFormatter.string(from: date)
}
