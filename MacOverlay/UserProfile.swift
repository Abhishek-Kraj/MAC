import Foundation

struct UserProfile: Codable {
    /// Used for `{NAME}` substitution in prompts and the calendar-reminder
    /// greeting. Role and company were removable: nothing in the user's
    /// prompts consumed `{ROLE}`/`{COMPANY}`, so they were fields whose only
    /// effect was to fill other unused fields.
    var name: String = ""
}

class UserProfileManager {
    static let shared = UserProfileManager()
    private let key = "userProfile"

    func load() -> UserProfile {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        else { return UserProfile() }
        return profile
    }

    func save(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
