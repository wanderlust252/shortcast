import Foundation

enum PublishingProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case uploadPost
    case tiktokOfficial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uploadPost:      "Upload-Post"
        case .tiktokOfficial:  "TikTok official API"
        }
    }

    var publishButtonTitle: String {
        switch self {
        case .uploadPost:      "Publish to all three"
        case .tiktokOfficial:  "Upload to TikTok"
        }
    }
}

enum PlatformOutcome: Sendable, Equatable {
    case success(url: String?)
    case submitted
    case failure(String)
}

struct PublishReport: Sendable {
    var provider: PublishingProviderID
    var outcomes: [SocialPlatform: PlatformOutcome]
    var requestID: String?
    var rawResponse: String
}
