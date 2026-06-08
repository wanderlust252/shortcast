# YouTube & Instagram Official Publishing — Implementation Ideas

## Current Architecture Overview

ShortCast already has a well-designed provider-based publishing architecture:

```
PublishingProvider (protocol)
├── UploadPostProvider     → All 3 platforms (unified REST API)
└── TikTokOfficialProvider → TikTok only (direct API)
```

The `PostVariant` model already supports all three platforms (`tiktok`, `instagram`, `youtube`), and the UI already renders platform-specific cards. The gap is **official API providers** for YouTube and Instagram.

---

## 🎯 Key Insight: Provider-per-Platform Architecture

Instead of a single provider that handles all platforms, adopt a **per-platform provider** model:

```swift
enum PublishingProviderID: String, CaseIterable {
    case uploadPost          // Unified (all 3 platforms)
    case tiktokOfficial      // TikTok only
    case youtubeOfficial     // YouTube only
    case instagramOfficial   // Instagram only
}
```

This allows users to mix providers:
- TikTok → Official API (direct post)
- YouTube → Official API (upload + Shorts features)
- Instagram → Official API (Reels publishing)

---

## 📺 YouTube Official Provider

### API Overview

YouTube Data API v3 supports video upload via **resumable upload** protocol:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/upload/youtube/v3/videos` | POST | Upload video with metadata |
| `/youtube/v3/channels` | GET | Verify channel access |
| `/youtube/v3/videos` | GET | Check upload status |

### Authentication Flow

**Option A: Manual Token (like TikTok)**
- User obtains OAuth2 access token externally
- Paste into Settings
- Pros: Simple, fast to implement
- Cons: Tokens expire, manual refresh needed

**Option B: In-App OAuth (recommended)**
- Use `ASWebAuthenticationSession` for OAuth flow
- Store access + refresh tokens in Keychain
- Auto-refresh before publish
- Pros: Better UX, production-ready
- Cons: More complex implementation

### Implementation Sketch

```swift
struct YouTubeOfficialProvider: PublishingProvider {
    let id: PublishingProviderID = .youtubeOfficial
    let displayName = "YouTube Official API"
    let supportedPlatforms: Set<SocialPlatform> = [.youtube]
    
    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport {
        
        guard let variant = variants.first(where: { $0.platform == .youtube }) else {
            throw PublishingError.noVariantForPlatform(.youtube)
        }
        
        // 1. Build metadata
        let metadata = YouTubeVideoMetadata(
            title: variant.hook,
            description: buildYouTubeDescription(variant),
            tags: variant.hashtags,
            privacyStatus: scheduledDate != nil ? "private" : "public",
            categoryId: "22"  // People & Blogs
        )
        
        // 2. Initiate resumable upload
        let uploadURL = try await initResumableUpload(
            metadata: metadata,
            fileSize: try videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
            accessToken: settings.youtubeAccessToken
        )
        
        // 3. Upload video in chunks
        let videoID = try await uploadVideo(
            uploadURL: uploadURL,
            videoURL: videoURL,
            chunkSize: 10 * 1024 * 1024  // 10MB chunks
        )
        
        // 4. Schedule if needed
        if let scheduledDate = scheduledDate {
            try await scheduleVideo(
                videoID: videoID,
                publishAt: scheduledDate,
                accessToken: settings.youtubeAccessToken
            )
        }
        
        return PublishReport(
            provider: .youtubeOfficial,
            outcomes: [.youtube: .success(url: "https://youtu.be/\(videoID)")],
            requestID: videoID,
            rawResponse: ""
        )
    }
}
```

### YouTube-Specific Features

| Feature | API Support | Notes |
|---------|-------------|-------|
| **Title** | ✅ Required | Max 100 chars |
| **Description** | ✅ Required | Max 5000 chars |
| **Tags** | ✅ Optional | Up to 500 chars total |
| **Category** | ✅ Required | Enum (22 = People & Blogs) |
| **Privacy** | ✅ Required | public/private/unlisted |
| **Scheduling** | ✅ | Must be private first, then update |
| **Thumbnail** | ✅ | Custom thumbnail upload |
| **Shorts Metadata** | ⚠️ Limited | No explicit "Shorts" flag; vertical + <60s auto-classified |

### YouTube Shorts Detection

YouTube doesn't have an explicit "upload as Shorts" API. Instead:
- Videos **≤ 60 seconds** + **vertical (9:16)** → Auto-classified as Shorts
- ShortCast already reframes to 9:16 and generates short clips
- Ensure metadata doesn't interfere (no horizontal-only tags)

### Chunked Upload Strategy

```
┌─────────────────────────────────────────────┐
│ 1. POST /videos?uploadType=resumable        │
│    → Get upload URL                         │
├─────────────────────────────────────────────┤
│ 2. PUT {upload_url}                         │
│    Headers: Content-Range: bytes 0-10485759 │
│    Body: First 10MB                         │
├─────────────────────────────────────────────┤
│ 3. PUT {upload_url}                         │
│    Headers: Content-Range: bytes 10485760-..│
│    Body: Next 10MB                          │
├─────────────────────────────────────────────┤
│ ... (repeat until complete)                 │
├─────────────────────────────────────────────┤
│ Final PUT → 200 OK with video ID            │
└─────────────────────────────────────────────┘
```

### YouTube Settings in AppSettings

```swift
// New settings to add
youtubeClientKey: String
youtubeClientSecret: String
youtubeAccessToken: String
youtubeRefreshToken: String
youtubeChannelID: String
youtubeDefaultPrivacy: YouTubePrivacy  // .public, .private, .unlisted
youtubeDefaultCategory: String         // Default: "22"
```

---

## 📸 Instagram Official Provider

### API Overview

Instagram Graph API uses a **two-step process** for Reels:

| Step | Endpoint | Purpose |
|------|----------|---------|
| 1. Create Container | `POST /{ig-user-id}/media` | Create media container with video URL |
| 2. Publish | `POST /{ig-user-id}/media_publish` | Publish the container |

### Authentication Requirements

**Permissions needed:**
- `instagram_basic`
- `instagram_content_publish`
- `pages_read_engagement`

**Account type:** Must be Instagram Business or Creator account connected to a Facebook Page.

### Implementation Sketch

```swift
struct InstagramOfficialProvider: PublishingProvider {
    let id: PublishingProviderID = .instagramOfficial
    let displayName = "Instagram Official API"
    let supportedPlatforms: Set<SocialPlatform> = [.instagram]
    
    @MainActor func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        scheduledDate: Date?,
        settings: AppSettings
    ) async throws -> PublishReport {
        
        guard let variant = variants.first(where: { $0.platform == .instagram }) else {
            throw PublishingError.noVariantForPlatform(.instagram)
        }
        
        // 1. Upload video to temporary hosting
        //    (Instagram requires a public URL, not direct file upload)
        let publicVideoURL = try await uploadToTempHosting(videoURL: videoURL)
        
        // 2. Create Reel container
        let containerID = try await createReelContainer(
            videoURL: publicVideoURL,
            caption: buildInstagramCaption(variant),
            settings: settings
        )
        
        // 3. Wait for processing
        try await waitForProcessing(containerID: containerID, settings: settings)
        
        // 4. Publish
        let mediaID = try await publishContainer(
            containerID: containerID,
            settings: settings
        )
        
        return PublishReport(
            provider: .instagramOfficial,
            outcomes: [.instagram: .success(url: "https://www.instagram.com/reel/\(mediaID)")],
            requestID: mediaID,
            rawResponse: ""
        )
    }
}
```

### Instagram Reel Specifications

| Spec | Requirement | ShortCast Status |
|------|-------------|------------------|
| **Format** | MOV or MP4 | ✅ Already exports MP4 |
| **Codec** | H.264 or HEVC | ✅ Already uses H.264 |
| **Aspect Ratio** | 9:16 recommended | ✅ Already reframes |
| **Duration** | 3s – 15 min | ✅ Clips are short |
| **Max File Size** | 300MB | ✅ Shorts are small |
| **Max Resolution** | 1920px width | ✅ Standard |

### Caption Formatting

Instagram has strict limits:
- **Max 2200 characters**
- **Max 30 hashtags**
- **Max 20 @ mentions**

```swift
func buildInstagramCaption(_ variant: PostVariant) -> String {
    var caption = variant.hook
    if !variant.summary.isEmpty {
        caption += "\n\n" + variant.summary
    }
    // Add hashtags (respect 30 limit)
    let hashtags = Array(variant.hashtags.prefix(30))
    if !hashtags.isEmpty {
        caption += "\n\n" + hashtags.map { "#\($0)" }.joined(separator: " ")
    }
    return caption
}
```

### The Hosting Challenge

**Critical Issue:** Instagram requires a **public URL** for the video, not a direct file upload.

**Solutions:**

| Approach | Pros | Cons |
|----------|------|------|
| **Temporary S3/Cloud Storage** | Reliable, scalable | Requires cloud account, costs |
| **ngrok/local server** | Free, no cloud needed | Unreliable, requires network setup |
| **Upload-Post as relay** | Already integrated | Adds dependency, slower |
| **Instagram's resumable upload** | Official method | Complex, needs chunked upload |

**Recommended:** Use Instagram's **resumable upload** protocol:

```swift
// Step 1: Initialize upload session
POST https://rupload.facebook.com/ig-api-upload/v25.0/{container_id}
Content-Type: application/octet-stream
Content-Length: {file_size}
Authorization: Bearer {access_token}

// Step 2: Upload video chunks
PUT https://rupload.facebook.com/ig-api-upload/v25.0/{container_id}
Content-Type: application/octet-stream
Content-Range: bytes {start}-{end}/{total}
Authorization: Bearer {access_token}
```

### Instagram Settings in AppSettings

```swift
// New settings to add
instagramAccessToken: String
instagramUserID: String          // IG User ID
instagramPageID: String          // Connected Facebook Page ID
instagramDefaultShareToFeed: Bool  // Show in feed too
```

---

## 🔧 Unified Settings UI Design

### Provider Selection Per Platform

Replace single provider picker with per-platform selection:

```
┌─────────────────────────────────────────────────────┐
│ Publishing Providers                                │
├─────────────────────────────────────────────────────┤
│ TikTok:        [TikTok Official API ▼]             │
│ YouTube:       [YouTube Official API ▼]             │
│ Instagram:     [Instagram Official API ▼]           │
│                                                     │
│ Or use [Upload-Post] for all platforms              │
└─────────────────────────────────────────────────────┘
```

### Settings Structure

```swift
struct PlatformProviderConfig: Codable, Sendable {
    var platform: SocialPlatform
    var providerID: PublishingProviderID
    var credentials: PlatformCredentials
}

enum PlatformCredentials: Codable, Sendable {
    case tiktok(clientKey: String, clientSecret: String, accessToken: String)
    case youtube(clientKey: String, clientSecret: String, accessToken: String, refreshToken: String)
    case instagram(accessToken: String, userID: String, pageID: String)
    case uploadPost(apiKey: String)
}
```

---

## 📋 Implementation Roadmap

### Phase 1: YouTube Official (Week 1-2)

1. **Create `YouTubeOfficialProvider.swift`**
   - Implement `PublishingProvider` protocol
   - Add resumable upload logic
   - Handle OAuth token exchange

2. **Add YouTube settings to `AppSettings`**
   - `youtubeClientKey`, `youtubeClientSecret`
   - `youtubeAccessToken`, `youtubeRefreshToken`
   - `youtubeChannelID`, `youtubeDefaultPrivacy`

3. **Update Settings UI**
   - Add YouTube provider picker
   - Add credential input fields
   - Add "Test YouTube" button

4. **Test with real YouTube channel**
   - Verify upload works
   - Verify Shorts classification
   - Test scheduling

### Phase 2: Instagram Official (Week 3-4)

1. **Create `InstagramOfficialProvider.swift`**
   - Implement `PublishingProvider` protocol
   - Add resumable upload to Instagram
   - Handle container creation + publishing

2. **Add Instagram settings to `AppSettings`**
   - `instagramAccessToken`, `instagramUserID`
   - `instagramPageID`

3. **Update Settings UI**
   - Add Instagram provider picker
   - Add credential input fields
   - Add "Test Instagram" button

4. **Test with real Instagram Business account**
   - Verify Reel publishing
   - Verify caption/hashtag limits
   - Test feed sharing

### Phase 3: Multi-Provider Mix (Week 5)

1. **Update provider selection UI**
   - Per-platform provider picker
   - Support mixed providers

2. **Update publish flow**
   - Filter variants per provider
   - Parallel publishing to different providers

3. **Update batch operations**
   - Schedule with mixed providers
   - Handle per-provider limits

---

## ⚠️ Key Challenges & Solutions

### Challenge 1: Instagram Video Hosting

**Problem:** Instagram requires public URL, but ShortCast renders locally.

**Solution:** Use Instagram's resumable upload protocol (no external hosting needed).

### Challenge 2: OAuth Token Management

**Problem:** Tokens expire, need refresh flow.

**Solution:**
- Store refresh tokens in Keychain
- Auto-refresh before publish
- Show token expiry in Settings
- Provide manual refresh button

### Challenge 3: Rate Limits

**Problem:** YouTube (100 uploads/day), Instagram (400 containers/day).

**Solution:**
- Track upload count in `AppSettings`
- Show remaining quota in UI
- Warn before batch publish

### Challenge 4: Scheduling Complexity

**Problem:** YouTube requires private→public update, Instagram doesn't support scheduling.

**Solution:**
- YouTube: Upload as private, then update visibility
- Instagram: Use Upload-Post for scheduling, official API for immediate

### Challenge 5: Error Handling

**Problem:** Different error formats per platform.

**Solution:**
- Normalize errors to `PublishReport` model
- Show platform-specific error messages
- Provide retry logic for transient failures

---

## 🔗 Reference Links

### YouTube
- [YouTube Data API v3 - Videos: insert](https://developers.google.com/youtube/v3/docs/videos/insert)
- [Resumable Upload Protocol](https://developers.google.com/youtube/v3/guides/resumable_upload_protocol)
- [OAuth 2.0 for iOS](https://developers.google.com/identity/protocols/oauth2/native-app)
- [YouTube Shorts Guidelines](https://support.google.com/youtube/answer/10094811)

### Instagram
- [Instagram Graph API - Media](https://developers.facebook.com/docs/instagram-platform/reference/ig-user/media)
- [Reels Publishing Guide](https://developers.facebook.com/docs/instagram-platform/guides/reels-publishing)
- [Resumable Upload for Reels](https://developers.facebook.com/docs/instagram-platform/insights/instagram-updates#upload-video-via-resumable-upload-protocol)
- [Instagram Business Account Requirements](https://developers.facebook.com/docs/instagram-platform/getting-started)

---

## 💡 Bonus Ideas

### 1. Platform-Specific Optimization

```swift
func optimizeForPlatform(_ platform: SocialPlatform, clip: ShortClip) {
    switch platform {
    case .youtube:
        // YouTube Shorts: Ensure ≤60s, vertical, catchy title
        clip.maxDuration = 60
        clip.aspectRatio = .nineToSixteen
    case .instagram:
        // Instagram Reels: Max 90s, trending audio hooks
        clip.maxDuration = 90
        clip.aspectRatio = .nineToSixteen
    case .tiktok:
        // TikTok: Max 3min, hook in first 3s
        clip.maxDuration = 180
        clip.aspectRatio = .nineToSixteen
    }
}
```

### 2. Cross-Platform Analytics

Track performance per platform:
- Views, likes, shares, comments
- Best posting times
- Hashtag performance

### 3. AI-Powered Hashtag Suggestions

Use Gemma/Qwen to suggest platform-specific hashtags:
- YouTube: SEO-optimized tags
- Instagram: Trending hashtags
- TikTok: Viral sound hashtags

### 4. Draft Mode for All Platforms

Extend `tiktokAsDraft` to all platforms:
- YouTube: Upload as unlisted
- Instagram: Save as draft (requires manual publish)
- TikTok: Already supported

---

## Summary

The current architecture is **perfectly designed** for extending to YouTube and Instagram official providers. The key decisions are:

1. **Provider-per-platform** model (not unified)
2. **In-app OAuth** for production quality
3. **Resumable upload** for Instagram (no external hosting)
4. **Chunked upload** for large files on both platforms
5. **Per-platform settings** in unified UI

Estimated effort: **4-5 weeks** for production-ready implementation.
