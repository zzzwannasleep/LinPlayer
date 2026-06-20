import Foundation

// MARK: - Auth

struct AuthResult: Codable {
    let accessToken: String
    let userId: String
    let serverId: String
    let user: EmbyUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case userId = "UserId"
        case serverId = "ServerId"
        case user = "User"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId) ?? ""
        user = try c.decode(EmbyUser.self, forKey: .user)
        userId = user.id
    }
}

struct EmbyUser: Codable, Identifiable {
    let id: String
    let name: String
    let primaryImageTag: String?
    let hasPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword"
    }

    init(id: String, name: String, primaryImageTag: String? = nil, hasPassword: Bool? = nil) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
        self.hasPassword = hasPassword
    }
}

// MARK: - Server

struct ServerInfo: Codable {
    let id: String
    let serverName: String
    let version: String
    let productName: String?
    let operatingSystem: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case operatingSystem = "OperatingSystem"
    }
}

struct ServerConfig: Codable, Identifiable {
    var id: String { url }
    var url: String
    var name: String
    var userId: String?
    var accessToken: String?

    var isAuthenticated: Bool {
        accessToken != nil && userId != nil
    }
}

// MARK: - Media Item

struct MediaItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let communityRating: Double?
    let officialRating: String?
    let premiereDate: String?
    let runTimeTicks: Int?
    let productionYear: Int?
    let genres: [String]?
    let seriesName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesId: String?
    let seasonId: String?
    let mediaType: String?
    let childCount: Int?
    let recursiveItemCount: Int?
    let userData: UserItemData?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentThumbItemId: String?
    let parentThumbImageTag: String?
    let parentPrimaryImageItemId: String?
    let parentPrimaryImageTag: String?
    let seriesThumbImageTag: String?
    let seriesPrimaryImageTag: String?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let people: [PersonInfo]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case premiereDate = "PremiereDate"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case genres = "Genres"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case mediaType = "MediaType"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case seriesThumbImageTag = "SeriesThumbImageTag"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case people = "People"
    }

    var primaryImageTag: String? {
        imageTags?["Primary"]
    }

    var thumbImageTag: String? {
        imageTags?["Thumb"]
    }

    var backdropImageTag: String? {
        backdropImageTags?.first ?? imageTags?["Backdrop"]
    }

    /// 有 Logo 的项目 ID（优先自身，否则父级）
    var logoItemId: String? {
        if imageTags?["Logo"] != nil { return id }
        return parentLogoItemId
    }

    /// Logo 缓存 tag（优先自身，否则父级）
    var logoImageTag: String? {
        imageTags?["Logo"] ?? parentLogoImageTag
    }

    var formattedRuntime: String? {
        guard let ticks = runTimeTicks else { return nil }
        let totalMinutes = ticks / 10_000_000 / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var isWatched: Bool {
        userData?.played ?? false
    }

    var progress: Double? {
        guard let pos = userData?.playbackPositionTicks, let total = runTimeTicks, total > 0 else {
            return nil
        }
        return Double(pos) / Double(total)
    }

    var isMovie: Bool { type == "Movie" }
    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension MediaItem {
    /// 由剧集（Episode）构造一个用于播放/上报的 MediaItem
    static func fromEpisode(_ episode: Episode, seriesName: String?) -> MediaItem {
        MediaItem(
            id: episode.id, name: episode.name, type: "Episode",
            overview: episode.overview, communityRating: nil, officialRating: nil,
            premiereDate: nil, runTimeTicks: episode.runTimeTicks,
            productionYear: nil, genres: nil, seriesName: seriesName,
            indexNumber: episode.indexNumber, parentIndexNumber: nil,
            seriesId: episode.seriesId, seasonId: episode.seasonId,
            mediaType: "Video", childCount: nil, recursiveItemCount: nil,
            userData: episode.userData, imageTags: episode.imageTags,
            backdropImageTags: nil, parentThumbItemId: episode.parentThumbItemId,
            parentThumbImageTag: episode.parentThumbImageTag,
            parentPrimaryImageItemId: nil, parentPrimaryImageTag: nil,
            seriesThumbImageTag: nil, seriesPrimaryImageTag: nil,
            parentLogoItemId: nil, parentLogoImageTag: nil,
            people: nil
        )
    }
}

struct UserItemData: Codable {
    let playbackPositionTicks: Int?
    let played: Bool?
    let isFavorite: Bool?
    let playCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
    }
}

struct PersonInfo: Codable, Identifiable {
    let id: String
    let name: String
    let primaryImageTag: String?
    let role: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
        case role = "Role"
        case type = "Type"
    }
}

// MARK: - Library

struct MediaLibrary: Codable, Identifiable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
    }

    var primaryImageTag: String? {
        imageTags?["Primary"]
    }
}

// MARK: - Season & Episode

struct Season: Codable, Identifiable {
    let id: String
    let name: String
    let indexNumber: Int?
    let seriesId: String?
    let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case indexNumber = "IndexNumber"
        case seriesId = "SeriesId"
        case imageTags = "ImageTags"
    }

    var primaryImageTag: String? {
        imageTags?["Primary"]
    }
}

struct Episode: Codable, Identifiable {
    let id: String
    let name: String
    let indexNumber: Int?
    let seriesId: String?
    let seasonId: String?
    let runTimeTicks: Int?
    let overview: String?
    let userData: UserItemData?
    let imageTags: [String: String]?
    let parentThumbItemId: String?
    let parentThumbImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case indexNumber = "IndexNumber"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case runTimeTicks = "RunTimeTicks"
        case overview = "Overview"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
    }

    var primaryImageTag: String? {
        imageTags?["Primary"]
    }

    var thumbImageTag: String? {
        imageTags?["Thumb"]
    }

    var formattedRuntime: String? {
        guard let ticks = runTimeTicks else { return nil }
        let totalMinutes = ticks / 10_000_000 / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var progress: Double? {
        guard let pos = userData?.playbackPositionTicks, let total = runTimeTicks, total > 0 else {
            return nil
        }
        return Double(pos) / Double(total)
    }

    var isWatched: Bool {
        userData?.played ?? false
    }
}

// MARK: - Playback

struct PlaybackInfo: Codable {
    let mediaSources: [MediaSource]

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

struct MediaSource: Codable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int?
    let runTimeTicks: Int?
    let mediaStreams: [MediaStream]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case runTimeTicks = "RunTimeTicks"
        case mediaStreams = "MediaStreams"
    }

    var videoStreams: [MediaStream] {
        mediaStreams.filter { $0.type == "Video" }
    }

    var audioStreams: [MediaStream] {
        mediaStreams.filter { $0.type == "Audio" }
    }

    var subtitleStreams: [MediaStream] {
        mediaStreams.filter { $0.type == "Subtitle" }
    }
}

struct MediaStream: Codable, Identifiable {
    var id: Int { index }
    let index: Int
    let type: String
    let codec: String?
    let language: String?
    let title: String?
    let isDefault: Bool?
    let isExternal: Bool?
    let displayTitle: String?
    let width: Int?
    let height: Int?
    let channels: Int?
    let bitRate: Int?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case title = "Title"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case displayTitle = "DisplayTitle"
        case width = "Width"
        case height = "Height"
        case channels = "Channels"
        case bitRate = "BitRate"
    }

    var resolution: String {
        guard let h = height else { return "" }
        if h >= 2160 { return "4K" }
        if h >= 1080 { return "1080p" }
        if h >= 720 { return "720p" }
        return "\(h)p"
    }

    var readableLabel: String {
        if let dt = displayTitle, !dt.isEmpty { return dt }
        if let t = title, !t.isEmpty { return t }
        let lang = Self.languageName(language)
        let codecStr = codec?.uppercased() ?? ""
        if !codecStr.isEmpty {
            return "\(lang) \(codecStr)"
        }
        return lang
    }

    static func languageName(_ code: String?) -> String {
        guard let code = code?.lowercased(), !code.isEmpty else { return "未知" }
        let map: [String: String] = [
            "chi": "中文", "zh": "中文", "chs": "简体中文", "cht": "繁体中文",
            "zho": "中文", "eng": "英语", "en": "英语", "jpn": "日语", "ja": "日语",
            "kor": "韩语", "ko": "韩语", "fre": "法语", "fra": "法语",
            "ger": "德语", "deu": "德语", "spa": "西班牙语", "por": "葡萄牙语",
            "rus": "俄语", "ita": "意大利语", "tha": "泰语", "vie": "越南语",
            "und": "未知",
        ]
        return map[code] ?? code
    }
}

// MARK: - Media Counts

struct MediaCounts: Codable {
    let movieCount: Int
    let episodeCount: Int

    enum CodingKeys: String, CodingKey {
        case movieCount = "MovieCount"
        case episodeCount = "EpisodeCount"
    }

    var totalCount: Int { movieCount + episodeCount }
}

// MARK: - API Response Wrappers

struct ItemsResponse: Codable {
    let items: [MediaItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct LibraryResponse: Codable {
    let items: [MediaLibrary]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct SeasonResponse: Codable {
    let items: [Season]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct EpisodeResponse: Codable {
    let items: [Episode]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct SearchHintsResponse: Codable {
    let searchHints: [MediaItem]

    enum CodingKeys: String, CodingKey {
        case searchHints = "SearchHints"
    }
}
