import AppKit
import SwiftUI

extension LauncherView {
    func invalidateSearchRequests() {
        latestSearchID &+= 1
        searchTask?.cancel()
        searchTask = nil
    }

    func beginSearchRequest() -> UInt64 {
        latestSearchID &+= 1
        return latestSearchID
    }

    func refreshSearchResults() {
        guard !isCommandMode else { return }
        guard !isClipboardQuery, !isClipboardImageQuery else {
            invalidateSearchRequests()
            setInitialSelection()
            return
        }
        guard !hidesResultsForEmptyQuery else {
            invalidateSearchRequests()
            backendResults = []
            setInitialSelection()
            return
        }

        let currentQuery = query
        let searchLimit = AppConstants.Launcher.defaultSearchLimit
        let searchID = beginSearchRequest()
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: AppConstants.Launcher.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let rawResults = await Task.detached(priority: .userInitiated) {
                bridge.search(query: currentQuery, limit: searchLimit)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                publishSearchResults(rawResults, searchID: searchID, for: currentQuery)
            }
        }
    }

    /// Publishes results on the main actor only if this request is still the
    /// latest and the query hasn't changed out from under it.
    @MainActor
    private func publishSearchResults(
        _ results: [LauncherResult],
        searchID: UInt64,
        for requestedQuery: String
    ) {
        guard searchID == latestSearchID else { return }
        guard !isCommandMode, query == requestedQuery else { return }
        backendResults = results
        setInitialSelection()
    }

    func performWebSearchFromQuery() {
        guard !isCommandMode else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let lookupText = extractTranslationQuery(from: trimmed) {
            handleLookupTranslation(text: lookupText)
            isQueryFocused = true
            return
        }

        performWebSearch(for: trimmed)
    }

    /// Opens a Google search for `text` in the default browser.
    func performWebSearch(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components?.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }

    /// Fetches previously-opened URLs matching the current query, debounced and
    /// off the main thread (the lookup opens the DB).
    func refreshRecentURLs() {
        recentURLTask?.cancel()
        let currentQuery = query
        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard allowsSuggestionRows, !isTranslationQuery,
              trimmed.count >= AppConstants.Launcher.minSuggestionQueryLength
        else {
            if !recentURLEntries.isEmpty { recentURLEntries = [] }
            return
        }

        recentURLTask = Task {
            try? await Task.sleep(nanoseconds: AppConstants.Launcher.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let limit = AppConstants.Launcher.WebURL.recentLimit
            let entries = await Task.detached(priority: .userInitiated) {
                bridge.recentURLs(query: currentQuery, limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard query == currentQuery, !isCommandMode else { return }
                recentURLEntries = entries
                if selectedResultID == nil {
                    setInitialSelection()
                }
            }
        }
    }

    @discardableResult
    func reloadConfig(
        successMessage: String = "Config reloaded",
        successStyle: BannerStyle = .info,
        successDuration: Double = 2.0
    ) -> Bool {
        let result = themeStore.reloadFromConfig()
        let backendReloaded = bridge.reloadConfig()
        clipboardStore.reloadFromConfig()
        reloadQueryRetentionPolicy()

        var message = successMessage
        var style: BannerStyle = successStyle
        var duration: Double = successDuration
        var copyText: String? = nil

        let warnings = result.warnings
        if !backendReloaded {
            message = "Backend config reload failed"
            style = .error
            duration = 4.0
        } else if !warnings.isEmpty {
            message = warnings.joined(separator: ", ")
            style = .warning
            duration = 5.0
            copyText = warnings.joined(separator: "\n")
        }

        showBanner(message, style: style, copyText: copyText, duration: duration)
        if isCommandMode {
            commandFeedback = message
        }
        refreshSearchResults()
        focusActiveInput()
        return backendReloaded
    }

    func showBanner(
        _ message: String,
        style: BannerStyle = .info,
        copyText: String? = nil,
        duration: Double = 1.8
    ) {
        bannerTask?.cancel()
        bannerStyle = style
        bannerCopyText = copyText
        withAnimation(.easeOut(duration: 0.15)) {
            bannerMessage = message
        }

        bannerTask = Task {
            let ns = UInt64(max(0.6, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.15)) {
                    bannerMessage = nil
                    bannerCopyText = nil
                }
            }
        }
    }
}
