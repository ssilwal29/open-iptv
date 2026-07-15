import SwiftUI
import SwiftData

@MainActor
var modelDataContainer: ModelContainer { PersistenceController.shared }
