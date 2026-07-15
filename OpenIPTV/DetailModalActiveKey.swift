import SwiftUI

/// Propagates "detail-level modal is open" state up the view hierarchy so
/// the top chrome (logo + clock) in ContentView can blur in sync with the
/// detail view's page blur.
struct DetailModalActiveKey: PreferenceKey {
    static let defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
