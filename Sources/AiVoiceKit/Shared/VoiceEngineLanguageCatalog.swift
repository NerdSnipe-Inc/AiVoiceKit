// Sources/AiVoiceKit/Shared/VoiceEngineLanguageCatalog.swift
// Adapted from FluidVoice/Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift
// Changes: public access, removed SettingsStore/SwiftWhisper dependencies,
//          routing uses ASRModel instead of SettingsStore.SpeechModel.
import Foundation

/// A language supported by at least one ASR engine in AiVoiceKit.
public struct VoiceEngineLanguage: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let aliases: [String]
    public let isPopular: Bool

    public var popularDisplayName: String {
        self.id == "zh" ? "Mandarin" : self.displayName
    }

    public init(id: String, displayName: String, aliases: [String] = [], isPopular: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.isPopular = isPopular
    }
}

/// The ASR engine binding for a specific language+model combination.
public struct VoiceEngineLanguageRoute: Identifiable, Equatable, Sendable {
    public enum LanguageBinding: Equatable, Sendable {
        case automatic
        case appleSpeech(localeIdentifier: String)
        case whisper(languageCode: String)
        case parakeet
        case nemotron
        case cohere

        public var id: String {
            switch self {
            case .automatic:
                return "auto"
            case let .appleSpeech(localeIdentifier):
                return "apple-\(localeIdentifier)"
            case let .whisper(languageCode):
                return "whisper-\(languageCode)"
            case .parakeet:
                return "parakeet"
            case .nemotron:
                return "nemotron"
            case .cohere:
                return "cohere"
            }
        }
    }

    public let language: VoiceEngineLanguage
    public let model: ASRModel
    public let binding: LanguageBinding

    public var id: String {
        "\(self.language.id)-\(self.model.rawValue)-\(self.binding.id)"
    }

    public init(language: VoiceEngineLanguage, model: ASRModel, binding: LanguageBinding) {
        self.language = language
        self.model = model
        self.binding = binding
    }
}

/// Catalog of all languages supported by AiVoiceKit ASR engines,
/// with utilities for searching and resolving routing.
public enum VoiceEngineLanguageCatalog {

    // MARK: - Public query API

    public static func allLanguages(
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> [VoiceEngineLanguage] {
        self.languageDefinitions.filter { language in
            !Self.routes(for: language, availableModels: availableModels).isEmpty
        }
    }

    public static func popularLanguages(
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> [VoiceEngineLanguage] {
        self.allLanguages(availableModels: availableModels).filter(\.isPopular)
    }

    public static func searchableLanguages(
        query: String,
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> [VoiceEngineLanguage] {
        let languages = Self.allLanguages(availableModels: availableModels)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return languages }

        return languages.filter { language in
            language.displayName.lowercased().contains(normalizedQuery) ||
                language.id.lowercased().contains(normalizedQuery) ||
                language.aliases.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }

    public static func language(
        id: String,
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> VoiceEngineLanguage? {
        self.allLanguages(availableModels: availableModels).first { $0.id == id }
    }

    public static func routes(
        for language: VoiceEngineLanguage,
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> [VoiceEngineLanguageRoute] {
        self.routeCandidates(for: language).filter { route in
            availableModels.contains(route.model)
        }
    }

    public static func routes(
        forLanguageID languageID: String,
        availableModels: [ASRModel] = ASRModel.allCases
    ) -> [VoiceEngineLanguageRoute] {
        guard let language = Self.language(id: languageID, availableModels: availableModels) else {
            return []
        }
        return Self.routes(for: language, availableModels: availableModels)
    }

    // MARK: - Private routing

    private static func routeCandidates(for language: VoiceEngineLanguage) -> [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []

        // Parakeet: English-only v2 and v3 models
        if language.id == "en" {
            routes.append(Self.route(language, .parakeetV2, .parakeet))
            routes.append(Self.route(language, .parakeetFlash, .parakeet))
        }

        // Parakeet V3: EU languages
        if Self.parakeetV3LanguageIDs.contains(language.id) {
            routes.append(Self.route(language, .parakeetV3, .parakeet))
        }

        // Cohere Transcribe: supported languages
        if Self.cohereLanguageIDs.contains(language.id) {
            routes.append(Self.route(language, .cohereTranscribe, .cohere))
        }

        // Nemotron: streaming + offline
        if Self.nemotronLanguageIDs.contains(language.id) {
            routes.append(Self.route(language, .nemotronFast, .nemotron))
            routes.append(Self.route(language, .nemotronMultilingual, .nemotron))
        }

        // Whisper: most languages
        if let whisperCode = Self.whisperLanguageCodeMap[language.id] {
            routes.append(Self.route(language, .whisperSmall, .whisper(languageCode: whisperCode)))
        }

        // Apple Speech: locale-specific
        if let appleSpeechLocale = Self.appleSpeechLocaleMap[language.id] {
            routes.append(Self.route(language, .appleSpeech, .appleSpeech(localeIdentifier: appleSpeechLocale)))
        }

        return routes
    }

    private static func route(
        _ language: VoiceEngineLanguage,
        _ model: ASRModel,
        _ binding: VoiceEngineLanguageRoute.LanguageBinding
    ) -> VoiceEngineLanguageRoute {
        VoiceEngineLanguageRoute(language: language, model: model, binding: binding)
    }

    // MARK: - Language sets

    private static let popularLanguageIDs: Set<String> = [
        "en", "es", "fr", "de", "pt", "it", "ja", "ko", "zh", "hi", "ar",
    ]

    private static let parakeetV3LanguageIDs: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
        "sl", "es", "sv", "ru", "uk",
    ]

    private static let cohereLanguageIDs: Set<String> = [
        "ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh",
    ]

    private static let nemotronLanguageIDs: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "sv",
        "da", "no", "fi", "ru", "uk", "cs", "sk", "sl", "hr",
        "ro", "hu", "el", "bg", "et", "lv", "lt", "mt",
        "ja", "ko", "zh", "ar", "hi",
    ]

    private static let whisperLanguageCodeMap: [String: String] = {
        // All languages that Whisper supports (derived from the language definitions).
        // Whisper uses "iw" for Hebrew (legacy ISO 639-1).
        let supported: Set<String> = [
            "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs",
            "ca", "cs", "cy", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi",
            "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy",
            "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb",
            "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
            "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro", "ru",
            "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw",
            "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi",
            "yi", "yo", "zh",
        ]
        var map: [String: String] = [:]
        for id in supported {
            map[id] = id == "he" ? "iw" : id
        }
        return map
    }()

    private static let appleSpeechLocaleMap: [String: String] = [
        "ar": "ar-SA",
        "cs": "cs-CZ",
        "da": "da-DK",
        "de": "de-DE",
        "el": "el-GR",
        "en": "en-US",
        "es": "es-US",
        "fi": "fi-FI",
        "fr": "fr-FR",
        "he": "he-IL",
        "hi": "hi-IN",
        "hr": "hr-HR",
        "hu": "hu-HU",
        "id": "id-ID",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "ms": "ms-MY",
        "nl": "nl-NL",
        "no": "nb-NO",
        "pl": "pl-PL",
        "pt": "pt-BR",
        "ro": "ro-RO",
        "ru": "ru-RU",
        "sk": "sk-SK",
        "sv": "sv-SE",
        "th": "th-TH",
        "tr": "tr-TR",
        "uk": "uk-UA",
        "vi": "vi-VN",
        "zh": "zh-CN",
    ]

    // MARK: - Language definitions

    private static let languageDefinitions: [VoiceEngineLanguage] = [
        Self.language("af", "Afrikaans"),
        Self.language("am", "Amharic"),
        Self.language("ar", "Arabic", aliases: ["Arab"]),
        Self.language("as", "Assamese"),
        Self.language("az", "Azerbaijani"),
        Self.language("ba", "Bashkir"),
        Self.language("be", "Belarusian"),
        Self.language("bg", "Bulgarian"),
        Self.language("bn", "Bengali", aliases: ["Bangla"]),
        Self.language("bo", "Tibetan"),
        Self.language("br", "Breton"),
        Self.language("bs", "Bosnian"),
        Self.language("ca", "Catalan"),
        Self.language("cs", "Czech"),
        Self.language("cy", "Welsh"),
        Self.language("da", "Danish"),
        Self.language("de", "German", aliases: ["Deutsch"]),
        Self.language("el", "Greek"),
        Self.language("en", "English"),
        Self.language("es", "Spanish", aliases: ["Castilian"]),
        Self.language("et", "Estonian"),
        Self.language("eu", "Basque"),
        Self.language("fa", "Persian", aliases: ["Farsi"]),
        Self.language("fi", "Finnish"),
        Self.language("fo", "Faroese"),
        Self.language("fr", "French"),
        Self.language("gl", "Galician"),
        Self.language("gu", "Gujarati"),
        Self.language("ha", "Hausa"),
        Self.language("haw", "Hawaiian"),
        Self.language("he", "Hebrew"),
        Self.language("hi", "Hindi"),
        Self.language("hr", "Croatian"),
        Self.language("ht", "Haitian Creole"),
        Self.language("hu", "Hungarian"),
        Self.language("hy", "Armenian"),
        Self.language("id", "Indonesian"),
        Self.language("is", "Icelandic"),
        Self.language("it", "Italian"),
        Self.language("ja", "Japanese"),
        Self.language("jw", "Javanese"),
        Self.language("ka", "Georgian"),
        Self.language("kk", "Kazakh"),
        Self.language("km", "Khmer"),
        Self.language("kn", "Kannada"),
        Self.language("ko", "Korean"),
        Self.language("la", "Latin"),
        Self.language("lb", "Luxembourgish"),
        Self.language("ln", "Lingala"),
        Self.language("lo", "Lao"),
        Self.language("lt", "Lithuanian"),
        Self.language("lv", "Latvian"),
        Self.language("mg", "Malagasy"),
        Self.language("mi", "Maori"),
        Self.language("mk", "Macedonian"),
        Self.language("ml", "Malayalam"),
        Self.language("mn", "Mongolian"),
        Self.language("mr", "Marathi"),
        Self.language("ms", "Malay"),
        Self.language("mt", "Maltese"),
        Self.language("my", "Myanmar", aliases: ["Burmese"]),
        Self.language("ne", "Nepali"),
        Self.language("nl", "Dutch"),
        Self.language("nn", "Norwegian Nynorsk"),
        Self.language("no", "Norwegian", aliases: ["Norwegian Bokmal"]),
        Self.language("oc", "Occitan"),
        Self.language("pa", "Punjabi"),
        Self.language("pl", "Polish"),
        Self.language("ps", "Pashto"),
        Self.language("pt", "Portuguese"),
        Self.language("ro", "Romanian", aliases: ["Moldavian", "Moldovan"]),
        Self.language("ru", "Russian"),
        Self.language("sa", "Sanskrit"),
        Self.language("sd", "Sindhi"),
        Self.language("si", "Sinhala", aliases: ["Sinhalese"]),
        Self.language("sk", "Slovak"),
        Self.language("sl", "Slovenian"),
        Self.language("sn", "Shona"),
        Self.language("so", "Somali"),
        Self.language("sq", "Albanian"),
        Self.language("sr", "Serbian"),
        Self.language("su", "Sundanese"),
        Self.language("sv", "Swedish"),
        Self.language("sw", "Swahili"),
        Self.language("ta", "Tamil"),
        Self.language("te", "Telugu"),
        Self.language("tg", "Tajik"),
        Self.language("th", "Thai"),
        Self.language("tk", "Turkmen"),
        Self.language("tl", "Tagalog", aliases: ["Filipino"]),
        Self.language("tr", "Turkish"),
        Self.language("tt", "Tatar"),
        Self.language("uk", "Ukrainian"),
        Self.language("ur", "Urdu"),
        Self.language("uz", "Uzbek"),
        Self.language("vi", "Vietnamese"),
        Self.language("yi", "Yiddish"),
        Self.language("yo", "Yoruba"),
        Self.language("zh", "Mandarin Chinese", aliases: ["Chinese", "Mandarin"]),
    ]

    private static func language(
        _ id: String,
        _ displayName: String,
        aliases: [String] = []
    ) -> VoiceEngineLanguage {
        VoiceEngineLanguage(
            id: id,
            displayName: displayName,
            aliases: aliases,
            isPopular: self.popularLanguageIDs.contains(id)
        )
    }
}
