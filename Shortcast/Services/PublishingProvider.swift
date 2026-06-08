import Foundation

protocol PublishingProvider: Sendable {
    var id: PublishingProviderID { get }
    var displayName: String { get }
    var supportedPlatforms: Set<SocialPlatform> { get }

    @MainActor func checkConnection(settings: AppSettings) async throws
    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport
}

enum PublishingProviderFactory {
    static func make(_ id: PublishingProviderID) -> any PublishingProvider {
        switch id {
        case .uploadPost:
            UploadPostProvider()
        case .tiktokOfficial:
            TikTokOfficialProvider()
        }
    }
}

struct UploadPostProvider: PublishingProvider {
    let id: PublishingProviderID = .uploadPost
    let displayName = "Upload-Post"
    let supportedPlatforms: Set<SocialPlatform> = Set(SocialPlatform.allCases)

    @MainActor func checkConnection(settings: AppSettings) async throws {
        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        try await client.checkConnection()
    }

    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport {
        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        return try await client.publish(
            videoURL: videoURL,
            variants: variants,
            tiktokAsDraft: tiktokAsDraft,
            scheduledDate: scheduledDate)
    }
}
