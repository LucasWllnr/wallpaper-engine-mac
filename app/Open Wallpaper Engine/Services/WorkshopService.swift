//
//  WorkshopService.swift
//  Open Wallpaper Engine
//
//  Steam Workshop browsing without a Web API key: the public workshop page embeds the
//  full IPublishedFileService/QueryFiles response in <script id="valve-ssr-data">.
//

import Foundation

enum WorkshopSort: String, CaseIterable, Identifiable {
    case trendDay, trendWeek, trendMonth, trendThreeMonths, trendSixMonths, trendYear
    case topRated, mostRecent, lastUpdated, mostSubscribed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trendDay:          "Most Popular (Today)"
        case .trendWeek:         "Most Popular (Week)"
        case .trendMonth:        "Most Popular (Month)"
        case .trendThreeMonths:  "Most Popular (3 Months)"
        case .trendSixMonths:    "Most Popular (6 Months)"
        case .trendYear:         "Most Popular (Year)"
        case .topRated:          "Most Popular (All Time)"
        case .mostRecent:        "Most Recent"
        case .lastUpdated:       "Last Updated"
        case .mostSubscribed:    "Most Subscribed"
        }
    }

    /// `browsesort` and `days` parameters of steamcommunity.com/workshop/browse
    var queryItems: [URLQueryItem] {
        func trend(_ days: Int) -> [URLQueryItem] {
            [.init(name: "browsesort", value: "trend"), .init(name: "days", value: "\(days)")]
        }
        switch self {
        case .trendDay:          return trend(1)
        case .trendWeek:         return trend(7)
        case .trendMonth:        return trend(30)
        case .trendThreeMonths:  return trend(90)
        case .trendSixMonths:    return trend(180)
        case .trendYear:         return trend(365)
        case .topRated:          return [.init(name: "browsesort", value: "toprated")]
        case .mostRecent:        return [.init(name: "browsesort", value: "mostrecent")]
        case .lastUpdated:       return [.init(name: "browsesort", value: "lastupdated")]
        case .mostSubscribed:    return [.init(name: "browsesort", value: "totaluniquesubscribers")]
        }
    }
}

struct WorkshopQuery: Equatable {
    var searchText = ""
    var sort: WorkshopSort = .trendYear
    /// Every tag must match (Wallpaper Engine's "required tags")
    var requiredTags: [String] = []
    /// Tags of which none may match
    var excludedTags: [String] = []
    var page = 1
}

struct WorkshopTag: Codable, Hashable {
    var tag: String
    var display_name: String?
}

struct WorkshopItem: Codable, Identifiable, Hashable {
    var publishedfileid: String
    var creator: String?
    var title: String
    var preview_url: String?
    var short_description: String?
    var file_size: String?
    var tags: [WorkshopTag]?
    var subscriptions: Int?
    var lifetime_subscriptions: Int?
    var favorited: Int?
    var views: Int?
    var star_rating: Int?
    var total_votes: Int?
    var time_created: Int?
    var time_updated: Int?

    var id: String { publishedfileid }
    var previewURL: URL? { preview_url.flatMap(URL.init(string:)) }
    /// Resized by Steam's image CDN (10-20x lighter, GIFs stay animated) for grids
    var thumbnailURL: URL? {
        preview_url.flatMap { URL(string: $0 + "?imw=360&imh=360&ima=fit&impolicy=Letterbox") }
    }
    var pageURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(publishedfileid)")! }
    var sizeInBytes: Int64 { Int64(file_size ?? "") ?? 0 }
    var tagNames: [String] { (tags ?? []).map(\.tag) }

    /// Scene, Video, Web or Application
    var wallpaperType: String? {
        tagNames.first { ["Scene", "Video", "Web", "Application"].contains($0) }
    }

    var contentRating: String? {
        tagNames.first { ["Everyone", "Questionable", "Mature"].contains($0) }
    }
}

struct WorkshopPage {
    var totalCount = 0
    var totalPages = 0
    var currentPage = 1
    var items = [WorkshopItem]()
    /// steamid -> persona name
    var authors = [String: String]()
}

enum WorkshopError: LocalizedError {
    case badResponse(Int)
    case dataNotFound

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "Steam Workshop answered with HTTP \(code)."
        case .dataNotFound: "Steam Workshop page format changed: results not found."
        }
    }
}

final class WorkshopService {
    static let shared = WorkshopService()
    static let appID = 431960

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) OpenWallpaperEngine"]
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: configuration)
    }()

    func browseURL(for query: WorkshopQuery) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var items: [URLQueryItem] = [
            .init(name: "appid", value: "\(Self.appID)"),
            .init(name: "section", value: "readytouseitems"),
            .init(name: "p", value: "\(query.page)")
        ]
        let text = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            items += query.sort.queryItems
        } else {
            items += [.init(name: "searchtext", value: text), .init(name: "browsesort", value: "textsearch")]
        }
        items += query.requiredTags.map { .init(name: "requiredtags[]", value: $0) }
        items += query.excludedTags.map { .init(name: "excludedtags[]", value: $0) }
        components.queryItems = items
        return components.url!
    }

    func search(_ query: WorkshopQuery) async throws -> WorkshopPage {
        guard SteamWorkshopBridge.isAllowed else { throw SteamBridgeError.notAllowed }
        let (data, response) = try await session.data(from: browseURL(for: query))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WorkshopError.badResponse(http.statusCode)
        }
        return try Self.parse(html: String(decoding: data, as: UTF8.self))
    }

    /// Details of specific items (no key needed for this endpoint)
    func details(of ids: [String]) async throws -> [WorkshopItem] {
        guard !ids.isEmpty, SteamWorkshopBridge.isAllowed else { return [] }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        var body = URLComponents()
        body.queryItems = [.init(name: "itemcount", value: "\(ids.count)")]
            + ids.enumerated().map { .init(name: "publishedfileids[\($0.offset)]", value: $0.element) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        struct Envelope: Decodable {
            struct Response: Decodable { var publishedfiledetails: [Detail] }
            struct Detail: Decodable {
                var publishedfileid: String
                var result: Int
                var creator: String?
                var title: String?
                var preview_url: String?
                var description: String?
                var file_size: String?
                var tags: [WorkshopTag]?
                var subscriptions: Int?
                var lifetime_subscriptions: Int?
                var favorited: Int?
                var views: Int?
                var time_created: Int?
                var time_updated: Int?
            }
            var response: Response
        }
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Envelope.self, from: data).response.publishedfiledetails
            .filter { $0.result == 1 }
            .map {
                WorkshopItem(publishedfileid: $0.publishedfileid, creator: $0.creator, title: $0.title ?? "",
                             preview_url: $0.preview_url, short_description: $0.description,
                             file_size: $0.file_size, tags: $0.tags,
                             subscriptions: $0.subscriptions, lifetime_subscriptions: $0.lifetime_subscriptions,
                             favorited: $0.favorited, views: $0.views,
                             time_created: $0.time_created, time_updated: $0.time_updated)
            }
    }

    // MARK: - Page parsing

    static func parse(html: String) throws -> WorkshopPage {
        guard let start = html.range(of: #"<script type="application/json" id="valve-ssr-data""#),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let root = try JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
              let renderContext = root["renderContext"] as? [String: Any],
              let queryDataString = renderContext["queryData"] as? String,
              let queryData = try JSONSerialization.jsonObject(with: Data(queryDataString.utf8)) as? [String: Any],
              let queries = queryData["queries"] as? [[String: Any]]
        else { throw WorkshopError.dataNotFound }

        for query in queries {
            guard let state = query["state"] as? [String: Any],
                  let data = state["data"] as? [String: Any],
                  data["results"] != nil
            else { continue }

            struct Payload: Decodable {
                struct Player: Decodable {
                    struct PublicData: Decodable { var steamid: String; var persona_name: String? }
                    var public_data: PublicData?
                }
                var total_count: Int?
                var total_pages: Int?
                var current_page: Int?
                var results: [WorkshopItem]
                var creator_player_link_details: [Player]?
            }
            let payload = try JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: data))
            var authors = [String: String]()
            for player in payload.creator_player_link_details ?? [] {
                if let data = player.public_data, let name = data.persona_name { authors[data.steamid] = name }
            }
            return WorkshopPage(totalCount: payload.total_count ?? payload.results.count,
                                totalPages: payload.total_pages ?? 1,
                                currentPage: payload.current_page ?? 1,
                                items: payload.results,
                                authors: authors)
        }
        throw WorkshopError.dataNotFound
    }
}
