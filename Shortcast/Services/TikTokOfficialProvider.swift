import Foundation

enum TikTokOfficialError: LocalizedError {
    case notConfigured
    case directPostCannotSchedule
    case missingTikTokVariant
    case invalidUploadURL
    case http(status: Int, body: String)
    case api(code: String, message: String, logID: String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a TikTok user access token in Settings first."
        case .directPostCannotSchedule:
            return "TikTok's official API provider does not support Shortcast scheduling yet."
        case .missingTikTokVariant:
            return "No TikTok caption was generated for this video."
        case .invalidUploadURL:
            return "TikTok did not return a valid upload URL."
        case .http(let status, let body):
            return "TikTok returned HTTP \(status). \(body)"
        case .api(let code, let message, let logID):
            let suffix = logID.map { " (log_id: \($0))" } ?? ""
            return "TikTok API error \(code): \(message)\(suffix)"
        case .transport(let detail):
            return detail
        }
    }
}

struct TikTokOfficialProvider: PublishingProvider {
    let id: PublishingProviderID = .tiktokOfficial
    let displayName = "TikTok official API"
    let supportedPlatforms: Set<SocialPlatform> = [.tiktok]

    @MainActor func checkConnection(settings: AppSettings) async throws {
        guard !settings.tiktokAccessToken.trimmed.isEmpty else {
            throw TikTokOfficialError.notConfigured
        }

        // TikTok only exposes creator_info/query for Direct Post (`video.publish`).
        // Inbox Upload (`video.upload`) is validated when a real upload starts.
        guard settings.tiktokPublishMode == .directPost else { return }

        let client = TikTokContentPostingClient(accessToken: settings.tiktokAccessToken)
        _ = try await client.queryCreatorInfo()
    }

    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport {
        if scheduledDate != nil {
            throw TikTokOfficialError.directPostCannotSchedule
        }
        guard !settings.tiktokAccessToken.trimmed.isEmpty else {
            throw TikTokOfficialError.notConfigured
        }
        guard let tiktok = variants.first(where: { $0.platform == .tiktok }) else {
            throw TikTokOfficialError.missingTikTokVariant
        }

        let client = TikTokContentPostingClient(accessToken: settings.tiktokAccessToken)
        let publishID: String
        switch settings.tiktokPublishMode {
        case .inboxUpload:
            publishID = try await client.uploadToInbox(videoURL: videoURL)
        case .directPost:
            publishID = try await client.directPost(
                videoURL: videoURL,
                caption: Self.caption(for: tiktok),
                privacyLevel: settings.tiktokPrivacyLevel,
                disableDuet: settings.tiktokDisableDuet,
                disableStitch: settings.tiktokDisableStitch,
                disableComment: settings.tiktokDisableComment,
                isAIGC: settings.tiktokLabelAIGC)
        }

        return PublishReport(
            provider: .tiktokOfficial,
            outcomes: [.tiktok: .submitted],
            requestID: publishID,
            rawResponse: "TikTok publish_id: \(publishID)")
    }

    private static func caption(for variant: PostVariant) -> String {
        [variant.hook, variant.summary, variant.hashtagLine]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private struct TikTokContentPostingClient: Sendable {
    let accessToken: String

    private static let base = URL(string: "https://open.tiktokapis.com")!

    func queryCreatorInfo() async throws -> CreatorInfo {
        var request = URLRequest(url: Self.base.appending(path: "v2/post/publish/creator_info/query/"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken.trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let data = try await send(request)
        return try decodeEnvelope(CreatorInfo.self, from: data).data
    }

    func uploadToInbox(videoURL: URL) async throws -> String {
        let fileSize = try videoSize(videoURL)
        let initResponse: InitResponse = try await initializeUpload(
            path: "v2/post/publish/inbox/video/init/",
            body: [
                "source_info": [
                    "source": "FILE_UPLOAD",
                    "video_size": fileSize,
                    "chunk_size": fileSize,
                    "total_chunk_count": 1
                ] as [String: Any]
            ])
        try await upload(videoURL: videoURL, to: initResponse.uploadURL, fileSize: fileSize)
        return initResponse.publishID
    }

    func directPost(
        videoURL: URL,
        caption: String,
        privacyLevel: String,
        disableDuet: Bool,
        disableStitch: Bool,
        disableComment: Bool,
        isAIGC: Bool
    ) async throws -> String {
        let fileSize = try videoSize(videoURL)
        let initResponse: InitResponse = try await initializeUpload(
            path: "v2/post/publish/video/init/",
            body: [
                "post_info": [
                    "title": String(caption.prefix(2200)),
                    "privacy_level": privacyLevel.trimmed.isEmpty ? "SELF_ONLY" : privacyLevel.trimmed,
                    "disable_duet": disableDuet,
                    "disable_stitch": disableStitch,
                    "disable_comment": disableComment,
                    "brand_content_toggle": false,
                    "brand_organic_toggle": false,
                    "is_aigc": isAIGC
                ] as [String: Any],
                "source_info": [
                    "source": "FILE_UPLOAD",
                    "video_size": fileSize,
                    "chunk_size": fileSize,
                    "total_chunk_count": 1
                ] as [String: Any]
            ])
        try await upload(videoURL: videoURL, to: initResponse.uploadURL, fileSize: fileSize)
        return initResponse.publishID
    }

    private func initializeUpload(path: String, body: [String: Any]) async throws -> InitResponse {
        var request = URLRequest(url: Self.base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken.trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        return try decodeEnvelope(InitResponse.self, from: data).data
    }

    private func upload(videoURL: URL, to uploadURLString: String?, fileSize: Int64) async throws {
        guard let uploadURLString,
              let uploadURL = URL(string: uploadURLString) else {
            throw TikTokOfficialError.invalidUploadURL
        }

        let videoData: Data
        do {
            videoData = try Data(contentsOf: videoURL)
        } catch {
            throw TikTokOfficialError.transport("Couldn't read the video file: \(error.localizedDescription)")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        request.setValue("bytes 0-\(fileSize - 1)/\(fileSize)", forHTTPHeaderField: "Content-Range")
        request.timeoutInterval = 300

        _ = try await send(request, uploadData: videoData)
    }

    private func send(_ request: URLRequest, uploadData: Data? = nil) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        let data: Data
        let response: URLResponse
        do {
            if let uploadData {
                (data, response) = try await session.upload(for: request, from: uploadData)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw TikTokOfficialError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TikTokOfficialError.http(status: http.statusCode, body: String(body.prefix(400)))
        }
        return data
    }

    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> TikTokEnvelope<T> {
        let envelope = try JSONDecoder().decode(TikTokEnvelope<T>.self, from: data)
        if envelope.error.code != "ok" {
            throw TikTokOfficialError.api(
                code: envelope.error.code,
                message: envelope.error.message,
                logID: envelope.error.logID)
        }
        return envelope
    }

    private func videoSize(_ url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch {
            throw TikTokOfficialError.transport("Couldn't inspect the video file: \(error.localizedDescription)")
        }
    }

    struct CreatorInfo: Decodable, Sendable {
        let privacyLevelOptions: [String]?

        private enum CodingKeys: String, CodingKey {
            case privacyLevelOptions = "privacy_level_options"
        }
    }

    struct InitResponse: Decodable, Sendable {
        let publishID: String
        let uploadURL: String?

        private enum CodingKeys: String, CodingKey {
            case publishID = "publish_id"
            case uploadURL = "upload_url"
        }
    }

    struct TikTokEnvelope<T: Decodable>: Decodable {
        let data: T
        let error: APIError
    }

    struct APIError: Decodable {
        let code: String
        let message: String
        let logID: String?

        private enum CodingKeys: String, CodingKey {
            case code
            case message
            case logID = "log_id"
        }
    }
}
