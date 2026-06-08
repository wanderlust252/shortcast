# TikTok Official Publishing Integration

Shortcast can publish TikTok through TikTok's official Content Posting API instead of
Upload-Post. This document explains the current manual-token integration and the
remaining work needed for a full OAuth flow.

## Current Scope

The app now has a provider layer:

- `UploadPostProvider`: wraps the existing `UploadPostClient` without changing the
  Upload-Post API request logic.
- `TikTokOfficialProvider`: uploads only the TikTok variant through TikTok's official
  API.

The shared publish result model lives in:

- `Shortcast/Models/PublishReport.swift`

The provider protocol and Upload-Post adapter live in:

- `Shortcast/Services/PublishingProvider.swift`

The TikTok official implementation lives in:

- `Shortcast/Services/TikTokOfficialProvider.swift`

## TikTok Developer Setup

Create or open a TikTok developer app in the TikTok developer portal:

- https://developers.tiktok.com/

Enable the Content Posting API products needed for the mode you want to test.

Shortcast supports two TikTok modes:

| Mode | Required scope | Behavior |
|------|----------------|----------|
| Inbox upload | `video.upload` | Uploads the video to TikTok inbox. The user finishes caption, privacy, and posting in TikTok. |
| Direct post | `video.publish` | Sends the video and caption to TikTok directly with privacy/comment/duet/stitch settings. |

Useful TikTok docs:

- Inbox upload: https://developers.tiktok.com/doc/content-posting-api-reference-upload-video
- Direct post: https://developers.tiktok.com/doc/content-posting-api-reference-direct-post
- Creator info: https://developers.tiktok.com/doc/content-posting-api-reference-query-creator-info

## Manual Token Flow

The current implementation does not run OAuth inside Shortcast yet. You provide the user
access token manually.

1. Use TikTok's OAuth flow or the developer tools available to your app to obtain a user
   access token.
2. Make sure the token includes the scope for the mode you will use:
   - `video.upload` for Inbox upload.
   - `video.publish` for Direct post.
3. Open Shortcast Settings.
4. Set `Publishing provider` to `TikTok official API`.
5. Paste:
   - `Client key`
   - `Client secret`
   - `User access token`
6. Choose `Inbox upload` or `Direct post`.
7. For Direct post, choose privacy and interaction settings.

Client key and client secret are stored for reference. The current code path only uses
the user access token when publishing.

## App Settings

The TikTok-related settings are stored in `AppSettings`:

- `tiktokClientKey`
- `tiktokClientSecret`
- `tiktokAccessToken`
- `tiktokPublishMode`
- `tiktokPrivacyLevel`
- `tiktokDisableDuet`
- `tiktokDisableStitch`
- `tiktokDisableComment`
- `tiktokLabelAIGC`

The active provider is selected with:

- `publishingProvider`

When `publishingProvider == .tiktokOfficial`, `AppSettings.isConfigured` only requires a
non-empty TikTok access token.

## Publish Behavior

When TikTok official API is selected:

1. Shortcast renders the clip exactly as it does for Upload-Post.
2. The publish flow filters variants to `.tiktok` only.
3. `TikTokOfficialProvider` builds the TikTok caption from:
   - hook
   - summary
   - hashtags
4. The provider initializes a TikTok upload session.
5. The provider uploads the MP4 with a single `PUT` request to TikTok's returned
   `upload_url`.
6. The result sheet shows the TikTok `publish_id` as the request ID.

Instagram and YouTube are not sent when this provider is selected.

## Inbox Upload

Inbox upload calls:

```text
POST https://open.tiktokapis.com/v2/post/publish/inbox/video/init/
PUT  {upload_url returned by TikTok}
```

The initialization body uses file upload mode:

```json
{
  "source_info": {
    "source": "FILE_UPLOAD",
    "video_size": 12345678,
    "chunk_size": 12345678,
    "total_chunk_count": 1
  }
}
```

This mode does not send caption text. The user finishes the post in TikTok.

## Direct Post

Direct post calls:

```text
POST https://open.tiktokapis.com/v2/post/publish/video/init/
PUT  {upload_url returned by TikTok}
```

The initialization body includes `post_info`:

```json
{
  "post_info": {
    "title": "caption text",
    "privacy_level": "SELF_ONLY",
    "disable_duet": false,
    "disable_stitch": false,
    "disable_comment": false,
    "brand_content_toggle": false,
    "brand_organic_toggle": false,
    "is_aigc": false
  },
  "source_info": {
    "source": "FILE_UPLOAD",
    "video_size": 12345678,
    "chunk_size": 12345678,
    "total_chunk_count": 1
  }
}
```

TikTok can restrict the valid privacy levels per creator account. If direct posting fails
with a privacy-related API error, try `SELF_ONLY` first.

## Limitations

- No in-app OAuth yet. Tokens must be obtained manually.
- No refresh-token handling yet. If a token expires, paste a new token in Settings.
- TikTok official API currently publishes only TikTok.
- Scheduling is disabled for TikTok official API.
- The upload code uses a single chunk. This is fine for normal shorts, but larger files
  may need chunked upload support later.
- `Test TikTok` can only fully validate Direct Post mode because TikTok's creator-info
  endpoint requires the direct-post scope. Inbox mode validates configuration during a
  real upload.

## Next Integration Steps

To make the integration production-grade:

1. Add an OAuth callback URL scheme to `Info.plist`.
2. Add an OAuth service that opens TikTok authorization in the browser.
3. Handle the redirect back into Shortcast.
4. Exchange authorization code for access token and refresh token.
5. Store access and refresh tokens locally.
6. Refresh tokens before publish when needed.
7. Query creator info before Direct Post and render the exact privacy options returned by
   TikTok instead of the static picker.
8. Add chunked upload support for larger rendered videos.
9. Add provider selection per platform, so TikTok can use official API while YouTube and
   Instagram use Upload-Post or future official providers.

## Provider Extension Pattern

Future official providers should implement `PublishingProvider`:

```swift
struct YouTubeOfficialProvider: PublishingProvider {
    let id: PublishingProviderID = .youtubeOfficial
    let displayName = "YouTube official API"
    let supportedPlatforms: Set<SocialPlatform> = [.youtube]

    @MainActor func checkConnection(settings: AppSettings) async throws {
        // Validate token or channel access.
    }

    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport {
        // Upload with the provider's official API and return PublishReport.
    }
}
```

Keep API-specific request/response handling inside the provider or a dedicated client.
Keep UI-facing status in the shared `PublishReport` model.
