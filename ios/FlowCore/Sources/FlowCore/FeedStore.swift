import Foundation
import Observation

@MainActor @Observable
public final class FeedStore {
    public private(set) var posts: [MediaPost] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasLoaded = false
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?
    public private(set) var query = FeedQuery()
    @ObservationIgnored private let client: any FeedServing
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var visitedCursors: Set<String> = []
    @ObservationIgnored private var generation = 0

    public init(client: any FeedServing = CivitaiClient()) { self.client = client }

    public func refresh(query: FeedQuery, token: String? = nil) async {
        generation += 1
        let current = generation
        self.query = query
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        posts = []
        cursor = nil
        visitedCursors = []
        hasMore = false
        defer { if generation == current { isLoading = false } }
        do {
            let page = try await client.fetch(query: query, cursor: nil, token: token)
            try Task.checkCancellation()
            guard generation == current else { return }
            append(page)
            hasLoaded = true
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func loadMore(token: String? = nil) async {
        guard !isLoading, !isLoadingMore, hasMore, let cursor else { return }
        let current = generation
        isLoadingMore = true
        errorMessage = nil
        defer { if current == generation { isLoadingMore = false } }
        do {
            let page = try await client.fetch(query: query, cursor: cursor, token: token)
            try Task.checkCancellation()
            guard generation == current else { return }
            visitedCursors.insert(cursor)
            append(page)
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func loadMoreIfNeeded(after post: MediaPost, token: String? = nil) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }), index >= posts.count - 5 else { return }
        await loadMore(token: token)
    }

    private func append(_ page: FeedPage) {
        var ids = Set(posts.map(\.id))
        posts.append(contentsOf: page.items.filter { $0.isSupportedMedia && $0.isSafeForWork && ids.insert($0.id).inserted })
        cursor = page.metadata?.nextCursor
        hasMore = cursor.map { !$0.isEmpty && !visitedCursors.contains($0) } ?? false
    }
}
