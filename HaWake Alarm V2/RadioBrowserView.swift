//
//  RadioBrowserView.swift
//  HaWake Alarm V2
//
//  Shared radio browser for Sleep Sounds listening and alarm station picking.
//  Search matches station names; place browsing stays in Near You's explicit
//  region control instead of adding another layer of tabs.
//
//  Page order: Now Playing card (when something is playing, with its own
//  heart) → collapsible Favorites → Top/Near You browse controls → results.
//  Favorites open only from the header tap or edit pencil, and close when
//  the user interacts anywhere outside the section.
//
//  Row taps play/pause. The heart favorites and prompts for a friendly display
//  name; favorite renaming lives in context menus and swipe actions.
//
//  Pick mode (alarm editor): tapping a row previews and selects it. Done hands
//  the station back without coupling selection to favoriting; with nothing
//  selected, Done is simply a dismiss (there is no separate Cancel button).
//

import SwiftUI
import CoreLocation
import MapKit

struct RadioBrowserView: View {
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    /// The app-wide theme accent for the current appearance.
    private var accent: Color { settings.appAccent(for: colorScheme) }
    /// Editor pick mode: Done returns the selected station via onPick.
    var pickMode: Bool = false
    /// "Edit" entry points land with Favorites expanded in edit mode;
    /// "New Station" entry points leave this false for plain browsing.
    var startInFavoritesEdit: Bool = false
    /// Live-mode pickers set this so Done hands the running preview off as
    /// the real session — the audio keeps playing instead of stopping and
    /// being restarted by the caller.
    var keepPlayingOnPick: Bool = false
    /// Analytics only: whether this picker is filling a SLEEP session rather
    /// than an alarm. Defaults to false, so every alarm-side call site (editor,
    /// sound picker, alarm defaults) is unchanged.
    var forSleepSession: Bool = false
    var onPick: ((RadioStation) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private let manager = RadioPlayerManager.shared

    private enum BrowseScope: Hashable {
        case top
        case nearYou
    }

    /// The manual Near You field can target a whole country or state/region.
    private enum PlaceIntent: Equatable {
        case country(code: String, displayName: String)
        case state(String)
    }

    @State private var searchText = ""
    @State private var scope: BrowseScope = .top
    @State private var results: [RadioStation] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var searchTask: Task<Void, Never>?
    /// Detected state/region name (e.g. "Michigan"); nil until resolved.
    @State private var detectedState: String?
    @State private var regionUnavailable = false
    /// User-entered region override for the Near You scope.
    @State private var manualRegion: String?
    /// When the manual region entry named a country, its ISO code — the
    /// Near You scope then browses that country instead of a state.
    @State private var manualCountryCode: String?
    @State private var regionInput = ""
    @FocusState private var regionFieldFocused: Bool
    /// True when the region fallback is due to denied/failed location
    /// access (drives the explanatory caption; a detected-country fallback
    /// doesn't need one).
    @State private var locationDenied = false
    // Pick mode state
    @State private var selectedForPick: RadioStation?
    @State private var startedPreview = false
    // Favorite naming / renaming
    @State private var namingStation: RadioStation?
    @State private var nameInput = ""
    @State private var showNamePrompt = false
    /// List edit mode for the Favorites section (pencil toolbar toggle).
    @State private var editMode: EditMode = .inactive
    /// Favorites section disclosure. Only a manual header tap (or the edit
    /// pencil) opens it; interacting anywhere outside the section closes it.
    @State private var favoritesExpanded = false
    // Pagination
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    @State private var nextOffset = 0
    /// Bumped whenever the query context changes so an in-flight page
    /// load can't append stale results to a new query.
    @State private var queryGeneration = 0
    private let pageSize = 50

    private var countryCode: String {
        Locale.current.region?.identifier ?? "US"
    }

    private var countryName: String {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    /// Region driving the Near You scope — manual entry beats auto-detect.
    private var effectiveRegion: String? {
        manualRegion ?? detectedState
    }

    /// Favorites have their own section; keeping them out of directory results
    /// avoids duplicate rows and duplicate favicon work.
    private var nonFavoriteResults: [RadioStation] {
        let favoriteIDs = Set(manager.favorites.map(\.id))
        return results.filter { !favoriteIDs.contains($0.id) }
    }

    /// Lowercased country names (device locale + English) → ISO code for the
    /// manual Near You region field.
    private static let countryCodeByName: [String: String] = {
        var map: [String: String] = [:]
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let id = region.identifier
            guard id.count == 2, id.allSatisfy(\.isLetter) else { continue }
            for locale in [Locale.current, english] {
                if let name = locale.localizedString(forRegionCode: id) {
                    map[name.lowercased()] = id
                }
            }
        }
        map["uk"] = "GB"
        map["usa"] = "US"
        return map
    }()

    private var resultsHeader: String {
        if !searchText.isEmpty { return "Search Results" }
        switch scope {
        case .top: return "Popular Stations"
        case .nearYou:
            if let effectiveRegion { return "Popular in \(effectiveRegion)" }
            return regionUnavailable ? "Popular in \(countryName)" : "Near You"
        }
    }

    var body: some View {
        List {
                if manager.currentStation != nil && manager.isActive {
                    Section("Now Playing") {
                        nowPlayingCard
                    }
                }

                if !manager.favorites.isEmpty {
                    favoritesSection
                }

                resultsSection
            }
            .environment(\.editMode, $editMode)
            .searchable(text: $searchText, prompt: "Search stations")
            .navigationTitle("Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // No Cancel button: Done doubles as the exit in pick mode
                // (no selection → plain dismiss, preview stops onDisappear).
                if !pickMode {
                    ToolbarItem(placement: .topBarLeading) {
                        sleepTimerMenu
                    }
                }
                if !manager.favorites.isEmpty {
                    // Pencil on the LEFT (by the sleep timer) — keeps the
                    // Done corner uncluttered.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation {
                                if editMode.isEditing {
                                    editMode = .inactive
                                } else {
                                    // Editing needs visible rows.
                                    favoritesExpanded = true
                                    editMode = .active
                                }
                            }
                        } label: {
                            Image(systemName: editMode.isEditing ? "pencil.circle.fill" : "pencil.circle")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        handleDone()
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                if !newValue.isEmpty {
                    collapseFavorites()
                }
                scheduleSearch(for: newValue)
            }
            .onChange(of: scope) { _, _ in
                reloadForScope()
            }
            .onChange(of: manager.favorites.isEmpty) { _, isEmpty in
                // Deleting the last favorite ends edit mode (its pencil
                // toggle disappears with the section).
                if isEmpty && editMode.isEditing {
                    editMode = .inactive
                }
            }
            .onChange(of: regionFieldFocused) { _, focused in
                if focused {
                    collapseFavorites()
                }
            }
            .task {
                if startInFavoritesEdit && !manager.favorites.isEmpty {
                    favoritesExpanded = true
                    editMode = .active
                }
                await loadScope()
            }
            .onDisappear {
                searchTask?.cancel()
                // A pick-mode preview must not linger as a listening session
                // after the sheet closes (cancel path included).
                if pickMode && startedPreview {
                    manager.stop()
                }
            }
            .onChange(of: detectedState) { _, newValue in
                // Auto-detect resolved after the field rendered — surface it,
                // unless the user is typing or has overridden the region.
                if !regionFieldFocused && manualRegion == nil {
                    regionInput = newValue ?? ""
                }
            }
            .alert(namingIsNew ? "Name This Favorite" : "Rename Favorite", isPresented: $showNamePrompt) {
                TextField("Station name", text: $nameInput)
                Button(namingIsNew ? "Add" : "Save") {
                    commitName()
                }
                Button("Cancel", role: .cancel) {
                    namingStation = nil
                }
            } message: {
                Text(namingIsNew
                     ? "This name is how the station appears in your favorites and alarm choices."
                     : "Alarms and favorites list this station by its name here.")
            }
            // Presented via a nested `.fullScreenCover` (inside the editor /
            // sound-picker sheets), which drops the app-root
            // `.preferredColorScheme` — leaving this screen in the device's
            // appearance while the rest of the app is forced light/dark, so it
            // read noticeably darker. Re-assert the app's appearance here so the
            // List's grouped background matches every menu leading into it.
            .preferredColorScheme(
                settings.appAppearance == "light" ? .light :
                settings.appAppearance == "dark" ? .dark : nil
            )
    }

    // MARK: - Sections

    /// Collapsible Favorites — the header chevron toggles the rows; edit
    /// mode forces them visible so reorder/delete has something to act on.
    private var favoritesSection: some View {
        Section {
            if favoritesExpanded || editMode.isEditing {
                ForEach(manager.favorites) { station in
                    stationRow(station)
                        .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    manager.favorites.remove(atOffsets: offsets)
                }
                .onMove { offsets, destination in
                    manager.favorites.move(fromOffsets: offsets, toOffset: destination)
                }
            }
        } header: {
            favoritesHeader
        }
    }

    private var resultsSection: some View {
        Section {
            if scope == .nearYou && regionUnavailable && locationDenied && searchText.isEmpty {
                Text("Location access is off — type a state, region, or country above, or allow location access to fill it in automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isLoading && results.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if loadFailed && results.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn't load stations")
                        .font(.headline)
                    Text("Check your connection and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        retryLoad()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 8)
            } else if results.isEmpty && !searchText.isEmpty && !isLoading {
                Text("No stations found for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nonFavoriteResults) { station in
                    stationRow(station)
                }
                if nonFavoriteResults.isEmpty && !results.isEmpty {
                    Text("All matching stations are already in Favorites.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // Infinite scroll: reaching this sentinel loads the
                // next page of the current query.
                if canLoadMore && !results.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear {
                        loadMoreResults()
                    }
                }
            }
        } header: {
            resultsSectionHeader
        }
    }

    /// Browse controls live in the section HEADER, not in rows: list rows
    /// are masked to the section card's corner radius, which visibly
    /// re-rounds the segment buttons' and region box's own corners. Header
    /// content is unclipped, so each control keeps its own shape. Search
    /// hides the controls (they're irrelevant to station-name search).
    @ViewBuilder
    private var resultsSectionHeader: some View {
        if searchText.isEmpty {
            // Zeroed insets so the controls span the full card width; the
            // title re-adds the standard header indent for itself.
            VStack(alignment: .leading, spacing: 8) {
                scopeControl
                if scope == .nearYou {
                    regionField
                }
                Text(resultsHeader)
                    .padding(.top, 6)
                    .padding(.leading, 20)
            }
            .listRowInsets(EdgeInsets())
            // Modest extra breathing room below the Favorites section.
            .padding(.top, 10)
            .padding(.bottom, 4)
        } else {
            Text(resultsHeader)
        }
    }

    // MARK: - Now Playing

    /// Media-player row above Favorites: artwork, station, pause/resume,
    /// and a heart so the current station can be favorited in place.
    @ViewBuilder
    private var nowPlayingCard: some View {
        if let station = manager.currentStation {
            HStack(spacing: 12) {
                stationArtwork(station, highlighted: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(station.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    playTapped(station)
                } label: {
                    RadioPlayCircle(
                        systemImage: manager.state == .playing
                            ? (pickMode ? "stop.fill" : "pause.fill")
                            : "play.fill",
                        isConnecting: manager.isConnecting,
                        diameter: 34,
                        fill: .solid(accent)
                    )
                }
                .buttonStyle(.borderless)

                Button {
                    if manager.isFavorite(station) {
                        manager.toggleFavorite(station)
                    } else {
                        promptForName(station)
                    }
                } label: {
                    Image(systemName: manager.isFavorite(station) ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundStyle(manager.isFavorite(station) ? .red : .secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Favorites header

    /// Favorites only stay open while the user is in them — interacting
    /// anywhere else on the page (scope tabs, region field, search, playing
    /// a non-favorite) closes the section. Edit mode is exempt: the rows
    /// must stay visible for reorder/delete.
    private func collapseFavorites() {
        guard favoritesExpanded, !editMode.isEditing else { return }
        withAnimation(.smooth(duration: 0.25)) {
            favoritesExpanded = false
        }
    }

    /// Collapsible section header — tapping anywhere toggles the disclosure.
    private var favoritesHeader: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) {
                favoritesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                // Bigger than a stock section header — Favorites is the
                // primary section on this page.
                Text("Favorites")
                    .font(.headline)
                if !favoritesExpanded {
                    // Collapsed rows hide everything — the count says
                    // what's inside without expanding.
                    Text("\(manager.favorites.count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .rotationEffect(.degrees(favoritesExpanded ? 0 : -90))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Favorite naming

    private var namingIsNew: Bool {
        guard let namingStation else { return false }
        return !manager.isFavorite(namingStation)
    }

    private func promptForName(_ station: RadioStation) {
        namingStation = station
        nameInput = station.name
        showNamePrompt = true
    }

    private func commitName() {
        guard let station = namingStation else { return }
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? station.name : trimmed
        if manager.isFavorite(station) {
            manager.renameFavorite(station, to: finalName)
        } else {
            var favorite = station
            favorite.name = finalName
            manager.favorites.append(favorite)
            Analytics.shared.log(.radioFavoriteAdded)
        }
        namingStation = nil
    }

    // MARK: - Scope control

    /// Scope tabs — the app's shared accent segment tiles, same style and height
    /// as the Sound Manager's categories and the command picker's type tabs.
    private var scopeControl: some View {
        AccentSegmentRow {
            scopeSegment(.top, title: "Top", icon: "flame.fill")
            scopeSegment(.nearYou, title: "Near You", icon: "location.fill")
        }
    }

    /// Inline region search field — type a state, region, or country and
    /// submit. No secondary prompt; the clear button returns to auto-detect.
    private var regionField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search any state, region, or country", text: $regionInput)
                .focused($regionFieldFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    applyRegionInput()
                }
            if !regionInput.isEmpty || manualRegion != nil {
                Button {
                    resetToAutoRegion()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear region, use my location")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func applyRegionInput() {
        let trimmed = regionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetToAutoRegion()
            return
        }
        regionUnavailable = false
        let intent = resolvePlaceIntent(for: trimmed)
        if case .country(let code, let displayName) = intent {
            manualCountryCode = code
            manualRegion = displayName
            regionInput = displayName
        } else {
            manualCountryCode = nil
            manualRegion = trimmed
        }
        reloadForScope()
    }

    /// Clear the manual override and fall back to the auto-detected region.
    private func resetToAutoRegion() {
        manualRegion = nil
        manualCountryCode = nil
        regionInput = detectedState ?? ""
        regionFieldFocused = false
        reloadForScope()
    }

    private func scopeSegment(_ value: BrowseScope, title: String, icon: String) -> some View {
        AccentSegmentTile(
            title: title,
            systemImage: icon,
            isSelected: scope == value,
            accent: accent
        ) {
            collapseFavorites()
            withAnimation(.smooth(duration: 0.2)) {
                // Tapping a tab while searching exits the search into that
                // scope (clearing the text triggers the reload).
                if !searchText.isEmpty { searchText = "" }
                scope = value
            }
        }
    }

    // MARK: - Sleep timer menu

    private var sleepTimerMenu: some View {
        Menu {
            if manager.sleepTimerEnd != nil {
                Button("Turn Off Timer", role: .destructive) {
                    manager.setSleepTimer(minutes: nil)
                }
            }
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button(minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(minutes) min") {
                    manager.setSleepTimer(minutes: minutes)
                }
            }
        } label: {
            Image(systemName: manager.sleepTimerEnd != nil ? "moon.zzz.fill" : "moon.zzz")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func stationRow(_ station: RadioStation) -> some View {
        let isCurrent = manager.currentStation?.id == station.id && manager.isActive
        let isSelected = pickMode && selectedForPick?.id == station.id
        HStack(spacing: 12) {
            stationArtwork(station, highlighted: isCurrent)

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(station.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent)
            }

            Button {
                playTapped(station)
            } label: {
                // Pick mode is a preview, so the active icon is stop;
                // the listening sheet keeps pause (real session with
                // lock-screen controls).
                RadioPlayCircle(
                    systemImage: isCurrent && manager.state == .playing
                        ? (pickMode ? "stop.fill" : "pause.fill")
                        : "play.fill",
                    isConnecting: isCurrent && manager.isConnecting,
                    diameter: 28,
                    fill: .solid(accent)
                )
            }
            .buttonStyle(.borderless)

            Button {
                if manager.isFavorite(station) {
                    manager.toggleFavorite(station)
                } else {
                    // Favoriting prompts for a display name (pre-filled
                    // with the station's real name).
                    promptForName(station)
                }
            } label: {
                Image(systemName: manager.isFavorite(station) ? "heart.fill" : "heart")
                    .font(.body)
                    .foregroundStyle(manager.isFavorite(station) ? .red : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playTapped(station)
        }
        .contextMenu {
            if let favorite = favorite(matching: station) {
                Button {
                    promptForName(favorite)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    manager.toggleFavorite(favorite)
                } label: {
                    Label("Remove Favorite", systemImage: "heart.slash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let favorite = favorite(matching: station) {
                Button {
                    promptForName(favorite)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(accent)

                Button(role: .destructive) {
                    manager.toggleFavorite(favorite)
                } label: {
                    Label("Remove", systemImage: "heart.slash")
                }
            }
        }
    }

    private func favorite(matching station: RadioStation) -> RadioStation? {
        manager.favorites.first { $0.id == station.id }
    }

    /// Play toggle shared by the row button and row tap. In pick mode,
    /// playing a station also selects it, and the
    /// active button is a STOP (it's a preview, not a listening session).
    private func playTapped(_ station: RadioStation) {
        // Playing from outside the Favorites section counts as leaving it.
        if favorite(matching: station) == nil {
            collapseFavorites()
        }
        let isCurrent = manager.currentStation?.id == station.id && manager.isActive
        if pickMode {
            if isCurrent && manager.state == .playing {
                manager.stop()
                startedPreview = false
                // Stopping the preview also clears the selection checkmark.
                selectedForPick = nil
                return
            }
            selectedForPick = station
            manager.play(station: station)
            startedPreview = true
            return
        }
        if isCurrent && manager.state == .playing {
            manager.pause()
        } else if isCurrent && manager.state == .paused {
            manager.resume()
        } else {
            manager.play(station: station)
        }
    }

    @ViewBuilder
    private func stationArtwork(_ station: RadioStation, highlighted: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 40, height: 40)
            if let url = station.secureFaviconURL {
                RadioFaviconView(url: url)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "radio")
                    .foregroundStyle(.secondary)
            }
            if highlighted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 40, height: 40)
                Image(systemName: manager.state == .playing ? "waveform" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Pick mode completion

    private func handleDone() {
        guard pickMode, let station = selectedForPick else {
            dismiss()
            return
        }
        finishPick(station)
    }

    private func finishPick(_ station: RadioStation) {
        if startedPreview {
            if keepPlayingOnPick && manager.isActive && manager.currentStation?.id == station.id {
                // Hand-off: the preview simply becomes the session. Clearing
                // startedPreview also keeps onDisappear from stopping it.
                startedPreview = false
            } else {
                manager.stop()
                startedPreview = false
            }
        }
        Analytics.shared.log(.radioStationPicked(forSleep: forSleepSession))
        onPick?(station)
        dismiss()
    }

    // MARK: - Loading

    private func reloadForScope() {
        searchTask?.cancel()
        searchTask = Task { await loadScope() }
    }

    private func retryLoad() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reloadForScope()
        } else {
            scheduleSearch(for: searchText, debounce: false)
        }
    }

    /// One page of the current query (search text beats browse scope) —
    /// shared by the initial load and infinite-scroll continuation.
    private func fetchPage(offset: Int) async throws -> [RadioStation] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return try await RadioBrowserAPI.shared.search(name: trimmed, limit: pageSize, offset: offset)
        }
        switch scope {
        case .top:
            return try await RadioBrowserAPI.shared.popular(limit: pageSize, offset: offset)
        case .nearYou:
            if let manualRegion {
                // Manual region skips the country filter — the entered
                // region may be anywhere. A country entry browses that
                // whole country instead.
                if let manualCountryCode {
                    return try await RadioBrowserAPI.shared.popular(countryCode: manualCountryCode, limit: pageSize, offset: offset)
                }
                return try await RadioBrowserAPI.shared.popular(state: manualRegion, limit: pageSize, offset: offset)
            }
            if let detectedState, !regionUnavailable {
                return try await RadioBrowserAPI.shared.popular(countryCode: countryCode, state: detectedState, limit: pageSize, offset: offset)
            }
            return try await RadioBrowserAPI.shared.popular(countryCode: countryCode, limit: pageSize, offset: offset)
        }
    }

    /// Manual region entries treat exact country names as countries and
    /// everything else as a state/region.
    private func resolvePlaceIntent(for term: String) -> PlaceIntent {
        if let code = Self.countryCodeByName[term.lowercased()] {
            let displayName = Locale.current.localizedString(forRegionCode: code) ?? term
            return .country(code: code, displayName: displayName)
        }
        return .state(term)
    }

    /// Whether a fetched page suggests more results exist. Pages come back
    /// short of `pageSize` when unplayable codecs are filtered out, so only
    /// a clearly-short page (< half) means the directory is exhausted.
    private func pageSuggestsMore(_ page: [RadioStation]) -> Bool {
        page.count >= pageSize / 2
    }

    private func loadScope() async {
        queryGeneration += 1
        let generation = queryGeneration
        isLoading = true
        loadFailed = false
        canLoadMore = false
        results = []
        defer {
            if generation == queryGeneration {
                isLoading = false
            }
        }
        do {
            if scope == .nearYou && manualRegion == nil {
                if detectedState == nil {
                    detectedState = await RadioRegionLocator.shared.detectState()
                    // Reverse geocoding sometimes hands back the COUNTRY name
                    // as the region ("United States"). Querying the directory
                    // with state == a country name matches only a few
                    // mislabeled stations, so treat it as country browsing.
                    if let detected = detectedState,
                       case .country = resolvePlaceIntent(for: detected) {
                        detectedState = nil
                    }
                }
                regionUnavailable = (detectedState == nil)
                locationDenied = !RadioRegionLocator.shared.isAuthorized
                guard !Task.isCancelled else { return }
            }
            let page = try await fetchPage(offset: 0)
            guard !Task.isCancelled, generation == queryGeneration else { return }
            results = page
            nextOffset = pageSize
            canLoadMore = pageSuggestsMore(page)
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            print("📻 RadioBrowserView: load failed — \(error)")
        }
    }

    private func scheduleSearch(for query: String, debounce: Bool = true) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Invalidate the previous query immediately. Otherwise its response
        // can land during the debounce window and appear under the new text.
        queryGeneration += 1
        let generation = queryGeneration
        isLoading = true
        loadFailed = false
        canLoadMore = false
        results = []
        searchTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled, generation == queryGeneration else { return }
            if trimmed.isEmpty {
                await loadScope()
                return
            }
            defer {
                if generation == queryGeneration {
                    isLoading = false
                }
            }
            do {
                let found = try await fetchPage(offset: 0)
                guard !Task.isCancelled, generation == queryGeneration else { return }
                results = found
                nextOffset = pageSize
                canLoadMore = pageSuggestsMore(found)
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
                print("📻 RadioBrowserView: search failed — \(error)")
            }
        }
    }

    /// Append the next page of the current query (infinite-scroll sentinel).
    private func loadMoreResults() {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        let generation = queryGeneration
        Task {
            defer { isLoadingMore = false }
            do {
                let page = try await fetchPage(offset: nextOffset)
                guard !Task.isCancelled, generation == queryGeneration else { return }
                nextOffset += pageSize
                let existingIDs = Set(results.map(\.id))
                results.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
                canLoadMore = pageSuggestsMore(page)
            } catch {
                guard generation == queryGeneration else { return }
                // Stop paging on error rather than retry-looping the sentinel.
                canLoadMore = false
            }
        }
    }
}

// MARK: - Region detection

/// Resolves the user's state/region name (e.g. "Michigan") for the
/// "Near You" browse scope. Awaits the permission prompt when status is
/// undetermined; returns nil (→ country fallback) when denied or unknown.
/// Same CLLocationManager + MKReverseGeocodingRequest pattern as
/// HaWakeWeatherService.
@MainActor
final class RadioRegionLocator: NSObject, CLLocationManagerDelegate {
    static let shared = RadioRegionLocator()

    private let manager = CLLocationManager()

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
    }

    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var locationTimeoutTask: Task<Void, Never>?
    private var authTimeoutTask: Task<Void, Never>?
    private var cachedState: String?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func detectState() async -> String? {
        if let cachedState { return cachedState }

        if manager.authorizationStatus == .notDetermined {
            await waitForAuthorization()
        }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        let location = await waitForLocation()
        guard let location else { return nil }

        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            // administrativeArea is the structured state ("Michigan").
            // addressRepresentations.regionName is the fallback — it
            // sometimes returns the country name, which the browser view
            // discards as unusable for a state query.
            cachedState = item.placemark.administrativeArea
                ?? item.addressRepresentations?.regionName
        }
        return cachedState
    }

    private func waitForAuthorization() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                finishAuthorizationWait()
                authContinuation = continuation
                manager.requestWhenInUseAuthorization()
                authTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.finishAuthorizationWait()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishAuthorizationWait()
            }
        }
    }

    private func waitForLocation() async -> CLLocation? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                finishLocationWait(with: nil)
                locationContinuation = continuation
                manager.requestLocation()
                locationTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.finishLocationWait(with: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLocationWait(with: nil)
            }
        }
    }

    private func finishAuthorizationWait() {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        guard let pending = authContinuation else { return }
        authContinuation = nil
        pending.resume()
    }

    private func finishLocationWait(with location: CLLocation?) {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        guard let pending = locationContinuation else { return }
        locationContinuation = nil
        pending.resume(returning: location)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.finishAuthorizationWait()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.first
        Task { @MainActor in
            self.finishLocationWait(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finishLocationWait(with: nil)
        }
    }
}
