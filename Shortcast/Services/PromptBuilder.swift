import Foundation

/// Assembles the full prompt handed to Gemma 4 alongside the video frames and
/// audio: the bundled educational editor brief, the creator's style, the
/// language instruction, and a strict JSON output contract.
enum PromptBuilder {

    /// Loads the bundled editor brief. Falls back to a terse
    /// built-in brief if the resource is somehow missing.
    static func coachDocument() -> String {
        guard let url = Bundle.main.url(forResource: "social-content-coach", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return fallbackCoach }
        return text
    }

    static func buildPrompt(languageOverride: String, styleExamples: String) -> String {
        buildPrompt(
            coach: coachDocument(),
            languageOverride: languageOverride,
            styleExamples: styleExamples)
    }

    /// Same as `buildPrompt(languageOverride:styleExamples:)` but with the coach
    /// document supplied directly — used by tests / the probe tool.
    static func buildPrompt(coach: String, languageOverride: String, styleExamples: String) -> String {
        assemble(coach: coach, languageOverride: languageOverride,
                 styleExamples: styleExamples, task: taskAndSchema)
    }

    /// Captioning prompt for the text-only Copywriter (Qwen). Same coach, style
    /// and JSON contract, but the content is the clip's transcript, not video.
    static func buildTranscriptPrompt(languageOverride: String, styleExamples: String) -> String {
        assemble(coach: coachDocument(), languageOverride: languageOverride,
                 styleExamples: styleExamples, task: transcriptTaskAndSchema)
    }

    private static func assemble(coach: String, languageOverride: String,
                                 styleExamples: String, task: String) -> String {
        var sections: [String] = [coach]

        let language = languageOverride.trimmed
        if language.isEmpty {
            sections.append("""
            ## Output language
            Write every field in the SAME language that is spoken in the clip — \
            detect it. Do not translate it to English. All user-facing text \
            (`hook` and `description`) must be in that language; keep only JSON \
            keys and legacy platform names in English.
            """)
        } else {
            sections.append("""
            ## Output language
            Write every field in this language: \(language). \
            Use it regardless of the language spoken in the clip. All \
            user-facing text (`hook` and `description`) must be in \(language); \
            keep only JSON keys and legacy platform names in English.
            """)
        }

        let style = styleExamples.trimmed
        if !style.isEmpty {
            sections.append("""
            ## Preferred writing style
            Below are examples of notes or summaries this creator likes. Mirror \
            their tone, rhythm, terminology, and formatting:

            \(style)
            """)
        }

        sections.append(task)
        return sections.joined(separator: "\n\n---\n\n")
    }

    private static let taskAndSchema = """
    ## Your task

    You have been given a video — its sampled frames and its audio track. Watch \
    and listen to it, then write a concise educational text package that can be \
    used for review, editing, and burned-in subtitle context.

    Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
    out loud. Use exactly this shape:

    {
      "language": "<BCP-47 code of the language you wrote in, e.g. vi, es, en>",
      "variants": [
        {
          "platform": "tiktok",
          "hook": "<plain-language title, 90 characters or fewer>",
          "description": "<1-2 sentence summary of the main idea>",
          "hashtags": []
        },
        {
          "platform": "instagram",
          "hook": "<descriptive section title>",
          "description": "<2-4 short paragraphs of study notes grounded in the video>",
          "hashtags": []
        },
        {
          "platform": "youtube",
          "hook": "<concise chapter title, about 40-60 characters>",
          "description": "<clear summary suitable for a video description or chapter note>",
          "hashtags": []
        }
      ]
    }

    Rules:
    - Keep `hashtags` as empty arrays; this app no longer asks for social tags.
    - Exactly three variants, in the order above, to preserve the app's legacy \
    editor layout.
    - Never invent facts that are not visible or audible in the video.
    - Output the JSON object and nothing else.
    """

    private static let transcriptTaskAndSchema = """
    ## Your task

    You have been given the transcript of one clip from a longer video. A \
    suggested title line is provided. Using the transcript, write a concise \
    educational text package for review and editing.

    Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
    out loud. Use exactly this shape:

    {
      "language": "<BCP-47 code of the language you wrote in, e.g. vi, es, en>",
      "variants": [
        {
          "platform": "tiktok",
          "hook": "<plain-language title, 90 characters or fewer>",
          "description": "<1-2 sentence summary of the main idea>",
          "hashtags": []
        },
        {
          "platform": "instagram",
          "hook": "<descriptive section title>",
          "description": "<2-4 short paragraphs of study notes grounded in the transcript>",
          "hashtags": []
        },
        {
          "platform": "youtube",
          "hook": "<concise chapter title, about 40-60 characters>",
          "description": "<clear summary suitable for a video description or chapter note>",
          "hashtags": []
        }
      ]
    }

    Rules:
    - Keep `hashtags` as empty arrays; this app no longer asks for social tags.
    - Exactly three variants, in the order above, to preserve the app's legacy \
    editor layout.
    - Never invent facts that are not in the transcript.
    - Output the JSON object and nothing else.
    """

    /// Used only if the bundled resource fails to load.
    private static let fallbackCoach = """
    # educational-content-editor (fallback)

    You are an expert educational video editor. Write grounded titles, concise \
    summaries, and subtitle-friendly text that match the actual content. Do not \
    add social-media framing, hashtags, or unsupported claims.
    """
}
