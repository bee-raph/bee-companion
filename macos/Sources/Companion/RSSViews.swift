import SwiftUI

struct RSSReaderView: View {
  @EnvironmentObject var model: AppModel
  @StateObject var data = ReaderData()
  @State var selection: String?
  var articles: [(RSSResponse.Feed, RSSResponse.Feed.Article)] {
    data.feeds.flatMap { feed in feed.articles.map { (feed, $0) } }.sorted {
      $0.1.published > $1.1.published
    }
  }
  var body: some View {
    HSplitView {
      VStack(alignment: .leading) {
        HStack {
          BeeSectionHeading(
            title: "Your reading room", subtitle: "Up to three RSS or Atom feeds",
            symbol: "dot.radiowaves.left.and.right")
          Spacer()
          Button("Refresh") {
            Task {
              await model.sync()
              await data.refresh(model)
            }
          }.disabled(data.refreshing)
        }.padding()
        if model.feedConfigurations.isEmpty {
          BeeEmptyState(
            title: "A quieter way to keep up",
            detail: "Add up to three RSS or Atom feed URLs in Settings → RSS & Shabbat mode.",
            symbol: "newspaper")
        } else {
          List(selection: $selection) {
            ForEach(data.feeds) { feed in
              SwiftUI.Section(feed.title + (feed.stale ? " · saved" : "")) {
                if let error = feed.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                ForEach(feed.articles) { article in
                  VStack(alignment: .leading, spacing: 5) {
                    Text(article.title).font(.headline)
                    Text(BeeDisplayTime.timestamp(article.published)).font(.caption)
                      .foregroundStyle(.secondary)
                  }.padding(.vertical, 7).tag(article.id)
                }
              }
            }
          }
        }
        ForEach(data.messages, id: \.self) {
          Text($0).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
      }.frame(minWidth: 300, idealWidth: 400)
      if let pair = articles.first(where: { $0.1.id == selection }) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text(pair.0.title.uppercased()).font(.caption).tracking(1).foregroundStyle(
              BeeTheme.accent)
            Text(pair.1.title).font(.system(size: 29, weight: .semibold))
            Text(BeeDisplayTime.timestamp(pair.1.published)).foregroundStyle(.secondary)
            Text(pair.1.summary).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
            if let url = URL(string: pair.1.url), ["http", "https"].contains(url.scheme ?? "") {
              Link("Read original article", destination: url)
            }
          }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        BeeEmptyState(
          title: "Something worth reading",
          detail: "Choose a headline to read its summary. Original articles open in your browser.",
          symbol: "book")
      }
    }
    .task(
      id: (model.configuration?.instanceID ?? "local") + (model.preferences.body["rssFeeds"] ?? "")
    ) {
      while !Task.isCancelled {
        await model.sync()
        await data.refresh(model)
        try? await Task.sleep(
          for: .seconds(ReaderPreferences.refreshSeconds(model.preferences.body)))
        if Task.isCancelled { break }
      }
    }
  }
}

struct ReadingSettingsView: View {
  @EnvironmentObject var model: AppModel
  @State var feeds: [FeedConfiguration] = []
  @State var refresh = 300
  @State var rotation = 15
  @State var stocks = Set<String>()
  @State var message = ""
  @State var editingFeed: FeedConfiguration?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("RSS & Shabbat mode").font(.title2)
      Text(
        "Configure up to three public RSS or Atom feeds. These preferences sync with your backend."
      ).font(.caption).foregroundStyle(.secondary)
      ForEach(feeds) { feed in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(feed.title.isEmpty ? "Untitled feed" : feed.title).font(.headline)
            Text(feed.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
          Button("Edit") { editingFeed = feed }
          Button("Remove", role: .destructive) {
            feeds.removeAll { $0.id == feed.id }
            saveFeeds()
          }
        }.padding(.vertical, 6)
      }
      Button("Add feed", systemImage: "plus") { editingFeed = FeedConfiguration() }.disabled(
        feeds.count >= 3)
      Picker("Automatic refresh", selection: $refresh) {
        ForEach([60, 120, 300, 600, 900, 1800, 3600], id: \.self) { Text("\($0 / 60) min").tag($0) }
      }
      Picker("Rotate headlines every", selection: $rotation) {
        ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
      }
      Text("Stocks on the Shabbat screen (up to six)").font(.headline)
      ForEach(model.items.filter { $0.kind == "watchlist_items" && !$0.deleted }) { item in
        Toggle(
          item.title + " · " + (item.body["symbol"] ?? ""),
          isOn: Binding(
            get: { stocks.contains(item.id) },
            set: { enabled in
              if enabled && stocks.count < 6 {
                stocks.insert(item.id)
              } else {
                stocks.remove(item.id)
              }
            })
        ).disabled(!stocks.contains(item.id) && stocks.count >= 6)
      }
      Text(
        "Weather and zmanim use the city coordinates and time zone above. ⌘⇧S opens Shabbat mode; Esc exits. The display stays awake while it is open."
      ).font(.caption).foregroundStyle(.secondary)
      Button("Save reader & Shabbat settings") { save() }.buttonStyle(.borderedProminent)
      Text(message).font(.caption).foregroundStyle(.secondary)
    }.onAppear { load() }.onChange(of: model.configuration?.instanceID) { _, _ in load() }
      .sheet(item: $editingFeed) { feed in
        FeedEditorSheet(feed: feed) { updated in
          if let index = feeds.firstIndex(where: { $0.id == updated.id }) {
            feeds[index] = updated
          } else if feeds.count < 3 {
            feeds.append(updated)
          }
          saveFeeds()
        }
      }
  }
  func saveFeeds() {
    do {
      try ReaderPreferences.validate(feeds)
      var item = model.preferences
      item.body["rssFeeds"] = String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self)
      model.save(item)
      message = "Feed changes saved. Synchronizing…"
      Task {
        await model.sync()
        message = model.message
      }
    } catch { message = error.localizedDescription }
  }
  func load() {
    feeds = model.feedConfigurations
    refresh = ReaderPreferences.refreshSeconds(model.preferences.body)
    rotation = ReaderPreferences.rotationSeconds(model.preferences.body)
    stocks = Set(ReaderPreferences.selectedStocks(model.preferences.body))
  }
  func save() {
    do {
      for index in feeds.indices {
        feeds[index].url = feeds[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      try ReaderPreferences.validate(feeds)
      var item = model.preferences
      item.body["rssFeeds"] = String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self)
      item.body["shabbatRefreshSeconds"] = String(refresh)
      item.body["shabbatRotationSeconds"] = String(rotation)
      item.body["shabbatStocks"] = String(
        decoding: try JSONEncoder().encode(stocks.sorted()), as: UTF8.self)
      model.save(item)
      message = "Saved locally. Synchronizing…"
      Task {
        await model.sync()
        message = model.message
      }
    } catch { message = error.localizedDescription }
  }
}

struct FeedEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var feed: FeedConfiguration
  var onSave: (FeedConfiguration) -> Void
  @State private var error = ""
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      BeeSectionHeading(
        title: "RSS feed", subtitle: "Enter a name and the RSS or Atom URL", symbol: "newspaper")
      VStack(alignment: .leading, spacing: 7) {
        Text("Feed name").font(.headline)
        TextField("For example, Daily news", text: $feed.title).textFieldStyle(.roundedBorder)
          .focused($focused)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Feed URL").font(.headline)
        TextField("https://example.com/feed.xml", text: $feed.url).textFieldStyle(.roundedBorder)
        Text("Use the feed address, rather than the publication’s homepage.").font(.caption)
          .foregroundStyle(.secondary)
      }
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save feed") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(
          .defaultAction)
      }
    }.padding(28).frame(width: 520).onAppear { focused = true }
  }
  func save() {
    do {
      feed.url = feed.url.trimmingCharacters(in: .whitespacesAndNewlines)
      feed.title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
      try ReaderPreferences.validate([feed])
      if feed.title.isEmpty { feed.title = URLComponents(string: feed.url)?.host ?? "RSS feed" }
      onSave(feed)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
