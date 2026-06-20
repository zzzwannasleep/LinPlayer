import Foundation

final class EmbyApiClient: ObservableObject {
    private let session: URLSession
    private(set) var baseURL: String
    private(set) var accessToken: String?
    private(set) var userId: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    static let mediaFields = [
        "Overview", "Genres", "CommunityRating", "OfficialRating", "PremiereDate",
        "RunTimeTicks", "ProductionYear", "Tags", "SeriesName", "IndexNumber",
        "ParentIndexNumber", "ImageTags", "ParentThumbItemId", "ParentThumbImageTag",
        "ParentPrimaryImageItemId", "ParentPrimaryImageTag", "SeriesThumbImageTag",
        "SeriesPrimaryImageTag", "BackdropImageTags", "ChildCount", "RecursiveItemCount",
        "People", "CanDownload", "SupportsSync", "ParentLogoItemId", "ParentLogoImageTag"
    ].joined(separator: ",")

    init(
        baseURL: String,
        accessToken: String? = nil,
        userId: String? = nil,
        allowInsecureTLS: Bool = false
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.accessToken = accessToken
        self.userId = userId

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        if allowInsecureTLS {
            // 仅当用户为该服务器显式信任自签名证书时，才放行坏证书。
            self.session = URLSession(
                configuration: config,
                delegate: InsecureSessionDelegate(),
                delegateQueue: nil
            )
        } else {
            // 默认走系统标准 TLS 校验，拒绝自签名/无效证书，防止中间人。
            self.session = URLSession(configuration: config)
        }
    }

    func setAuth(token: String, userId: String) {
        self.accessToken = token
        self.userId = userId
    }

    func clearAuth() {
        self.accessToken = nil
        self.userId = nil
    }

    // MARK: - Request Building

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        var components = URLComponents(string: baseURL + cleanPath)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        return components?.url
    }

    private func buildRequest(url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LinPlayer-tvOS/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue(
            "MediaBrowser Client=\"LinPlayer\", Device=\"Apple TV\", DeviceId=\"linplayer-tvos\", Version=\"1.0.0\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        request.setValue("Apple TV", forHTTPHeaderField: "X-Emby-Device-Name")
        request.setValue("linplayer-tvos", forHTTPHeaderField: "X-Emby-Device-Id")
        request.setValue("LinPlayer", forHTTPHeaderField: "X-Emby-Client")
        request.setValue("1.0.0", forHTTPHeaderField: "X-Emby-Client-Version")

        if let token = accessToken {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if let body = body {
            request.httpBody = body
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.httpError(statusCode: httpResponse.statusCode, data: data)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func performVoid(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.httpError(statusCode: httpResponse.statusCode, data: nil)
        }
    }

    private var currentUserId: String {
        userId ?? "Me"
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws -> AuthResult {
        guard let url = buildURL(path: "/Users/AuthenticateByName") else {
            throw EmbyError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ])
        let request = buildRequest(url: url, method: "POST", body: body)
        let result: AuthResult = try await perform(request)
        setAuth(token: result.accessToken, userId: result.userId)
        return result
    }

    func logout() async throws {
        guard let url = buildURL(path: "/Sessions/Logout") else { return }
        let request = buildRequest(url: url, method: "POST")
        try? await performVoid(request)
        clearAuth()
    }

    // MARK: - Server

    func getPublicInfo() async throws -> ServerInfo {
        guard let url = buildURL(path: "/System/Info/Public") else {
            throw EmbyError.invalidURL
        }
        let request = buildRequest(url: url)
        return try await perform(request)
    }

    static func testConnection(url: String, allowInsecureTLS: Bool = false) async throws -> ServerInfo {
        let client = EmbyApiClient(baseURL: url, allowInsecureTLS: allowInsecureTLS)
        return try await client.getPublicInfo()
    }

    // MARK: - Home

    func getResumeItems(limit: Int = 12) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items/Resume", queryItems: [
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    func getNextUp(limit: Int = 12) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Shows/NextUp", queryItems: [
            URLQueryItem(name: "UserId", value: currentUserId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    func getLibraries() async throws -> [MediaLibrary] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Views") else {
            throw EmbyError.invalidURL
        }
        let request = buildRequest(url: url)
        let response: LibraryResponse = try await perform(request)
        return response.items
    }

    func getLatestItems(libraryId: String, limit: Int = 20) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items/Latest", queryItems: [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        return try await perform(request)
    }

    func getRandomRecommendations(limit: Int = 8) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items", queryItems: [
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    // MARK: - Library

    func getLibraryItems(
        libraryId: String,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> [MediaItem] {
        var queryItems = [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "UserId", value: currentUserId),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]
        if let sortBy = sortBy {
            queryItems.append(URLQueryItem(name: "SortBy", value: sortBy))
            queryItems.append(URLQueryItem(name: "SortOrder", value: sortOrder ?? "Ascending"))
        }
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items", queryItems: queryItems) else {
            throw EmbyError.invalidURL
        }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    // MARK: - Media Details

    func getItemDetails(itemId: String) async throws -> MediaItem {
        guard let url = buildURL(path: "/Items/\(itemId)", queryItems: [
            URLQueryItem(name: "Fields", value: Self.mediaFields),
            URLQueryItem(name: "UserId", value: currentUserId),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        return try await perform(request)
    }

    func getSimilarItems(itemId: String, limit: Int = 12) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Items/\(itemId)/Similar", queryItems: [
            URLQueryItem(name: "UserId", value: currentUserId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    func getSeasons(seriesId: String) async throws -> [Season] {
        guard let url = buildURL(path: "/Shows/\(seriesId)/Seasons", queryItems: [
            URLQueryItem(name: "UserId", value: currentUserId),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags"),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: SeasonResponse = try await perform(request)
        return response.items
    }

    func getEpisodes(seriesId: String, seasonId: String? = nil) async throws -> [Episode] {
        var queryItems = [
            URLQueryItem(name: "UserId", value: currentUserId),
            URLQueryItem(name: "Fields", value: "Overview,RunTimeTicks,ImageTags,ParentThumbItemId,ParentThumbImageTag"),
        ]
        if let seasonId = seasonId {
            queryItems.append(URLQueryItem(name: "SeasonId", value: seasonId))
        }
        guard let url = buildURL(path: "/Shows/\(seriesId)/Episodes", queryItems: queryItems) else {
            throw EmbyError.invalidURL
        }
        let request = buildRequest(url: url)
        let response: EpisodeResponse = try await perform(request)
        return response.items
    }

    // MARK: - Search

    func search(query: String, limit: Int = 50) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items", queryItems: [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    // MARK: - Playback

    func getPlaybackInfo(itemId: String) async throws -> PlaybackInfo {
        guard let url = buildURL(path: "/Items/\(itemId)/PlaybackInfo") else {
            throw EmbyError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "UserId": currentUserId,
            "StartTimeTicks": 0,
            "IsPlayback": true,
            "AutoOpenLiveStream": true,
        ] as [String: Any])
        let request = buildRequest(url: url, method: "POST", body: body)
        return try await perform(request)
    }

    func getVideoStreamURL(
        itemId: String,
        mediaSourceId: String? = nil,
        container: String? = nil
    ) -> URL? {
        let safeContainer = (container ?? "mkv").lowercased()
        var params = [
            "static=true",
            "download=false",
            "EnableDirectPlay=true",
            "EnableDirectStream=true",
            "EnableTranscoding=false",
        ]
        if let msid = mediaSourceId, !msid.isEmpty {
            params.append("MediaSourceId=\(msid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? msid)")
        }
        if let token = accessToken {
            params.append("api_key=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)")
        }
        let urlString = "\(baseURL)/Videos/\(itemId)/stream.\(safeContainer)?\(params.joined(separator: "&"))"
        return URL(string: urlString)
    }

    func reportPlaybackStart(itemId: String, mediaSourceId: String) async throws {
        guard let url = buildURL(path: "/Sessions/Playing") else { return }
        let body = try JSONSerialization.data(withJSONObject: [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PlayMethod": "DirectStream",
        ])
        let request = buildRequest(url: url, method: "POST", body: body)
        try await performVoid(request)
    }

    func reportPlaybackProgress(itemId: String, mediaSourceId: String, positionTicks: Int, isPaused: Bool) async throws {
        guard let url = buildURL(path: "/Sessions/Playing/Progress") else { return }
        let body = try JSONSerialization.data(withJSONObject: [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "IsMuted": false,
            "VolumeLevel": 100,
        ] as [String: Any])
        let request = buildRequest(url: url, method: "POST", body: body)
        try await performVoid(request)
    }

    func reportPlaybackStopped(itemId: String, mediaSourceId: String, positionTicks: Int) async throws {
        guard let url = buildURL(path: "/Sessions/Playing/Stopped") else { return }
        let body = try JSONSerialization.data(withJSONObject: [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PositionTicks": positionTicks,
        ] as [String: Any])
        let request = buildRequest(url: url, method: "POST", body: body)
        try await performVoid(request)
    }

    // MARK: - Favorites

    func addFavorite(itemId: String) async throws {
        guard let url = buildURL(path: "/Users/\(currentUserId)/FavoriteItems/\(itemId)") else { return }
        let request = buildRequest(url: url, method: "POST")
        try await performVoid(request)
    }

    func removeFavorite(itemId: String) async throws {
        guard let url = buildURL(path: "/Users/\(currentUserId)/FavoriteItems/\(itemId)") else { return }
        let request = buildRequest(url: url, method: "DELETE")
        try await performVoid(request)
    }

    func getFavorites(limit: Int = 200) async throws -> [MediaItem] {
        guard let url = buildURL(path: "/Users/\(currentUserId)/Items", queryItems: [
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "DateCreated,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.mediaFields),
        ]) else { throw EmbyError.invalidURL }
        let request = buildRequest(url: url)
        let response: ItemsResponse = try await perform(request)
        return response.items
    }

    // MARK: - Images

    func imageURL(
        itemId: String,
        imageType: String = "Primary",
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil
    ) -> URL? {
        var params: [String] = []
        if let maxWidth = maxWidth { params.append("maxWidth=\(maxWidth)") }
        if let maxHeight = maxHeight { params.append("maxHeight=\(maxHeight)") }
        params.append("quality=90")
        if let token = accessToken { params.append("api_key=\(token)") }
        if let tag = tag { params.append("tag=\(tag)") }
        let urlString = "\(baseURL)/Items/\(itemId)/Images/\(imageType)?\(params.joined(separator: "&"))"
        return URL(string: urlString)
    }

    func primaryImageURL(_ itemId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL? {
        imageURL(itemId: itemId, imageType: "Primary", tag: tag, maxWidth: maxWidth)
    }

    func backdropImageURL(_ itemId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL? {
        imageURL(itemId: itemId, imageType: "Backdrop", tag: tag, maxWidth: maxWidth ?? 1920, maxHeight: 1080)
    }

    func thumbImageURL(_ itemId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL? {
        imageURL(itemId: itemId, imageType: "Thumb", tag: tag, maxWidth: maxWidth)
    }

    func logoImageURL(_ itemId: String, tag: String?, maxWidth: Int? = nil) -> URL? {
        guard tag != nil else { return nil }
        return imageURL(itemId: itemId, imageType: "Logo", tag: tag, maxWidth: maxWidth ?? 400)
    }
}

// MARK: - Errors

enum EmbyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, data: Data?)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .invalidResponse: return "无效的服务器响应"
        case .httpError(let code, _): return "服务器错误 (\(code))"
        case .notAuthenticated: return "未登录"
        }
    }
}

// MARK: - SSL Delegate

private class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
