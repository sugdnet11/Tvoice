import Foundation

struct LocalCallLog: Codable, Identifiable {
    let id: String
    let sipNumber: String
    let displayName: String
    let direction: String // "incoming", "outgoing", "missed"
    let timestamp: Date
    let isVideo: Bool
}

enum LocalCallHistoryStore {
    private static let key = "tvoice_local_call_history_v1"

    static func saveCall(sipNumber: String, displayName: String?, direction: String, isVideo: Bool) {
        var list = loadAll()
        let name = displayName?.isEmpty == false ? displayName! : sipNumber
        let newRecord = LocalCallLog(
            id: UUID().uuidString,
            sipNumber: sipNumber,
            displayName: name,
            direction: direction,
            timestamp: Date(),
            isVideo: isVideo
        )
        list.insert(newRecord, at: 0)
        
        // Keep last 100 call records
        if list.count > 100 {
            list = Array(list.prefix(100))
        }
        
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadAll() -> [LocalCallLog] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LocalCallLog].self, from: data) else {
            return []
        }
        return list
    }
}
