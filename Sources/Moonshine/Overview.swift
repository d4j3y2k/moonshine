import AppKit
import SwiftUI
import MoonshineCore

struct Overview: View {
    @ObservedObject var model: AppModel
    let searchReady: (NSTextField) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectingContext = false
    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header.opacity(model.spread ? 1 : 0)
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    previewCanvas
                        .onAppear { model.canvasSize = frame.size; model.canvasOrigin = frame.origin }
                        .onChange(of: frame) { _, frame in model.canvasSize = frame.size; model.canvasOrigin = frame.origin }
                }.padding(.horizontal, 48).padding(.top, 10).zIndex(1)
                if !model.shelfItems.isEmpty { browserShelf.padding(.horizontal, 48).padding(.top, 20).opacity(model.spread ? 1 : 0) }
                footer.opacity(model.spread ? 1 : 0)
            }.padding(.top, model.screenTopInset + 24).padding(.bottom, 22)
        }.preferredColorScheme(.dark)
    }
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.26), Color(red: 0.035, green: 0.065, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let wallpaper = model.wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill().opacity(0.62) }
            Color.black.opacity(0.30)
        }.clipped().ignoresSafeArea()
            // The desktop gives way quickly; the windows take a little longer to settle.
            .opacity(model.spread ? 1 : 0).animation(.easeOut(duration: 0.18), value: model.spread)
    }
    private var header: some View {
        ZStack {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(red: 0.54, green: 0.76, blue: 1))
                    .accessibilityHidden(true)
                SearchInput(text: Binding(get: { model.search.query }, set: { model.queryChanged($0) }), ready: searchReady)
                    .frame(height: 28)
                if !model.search.query.isEmpty {
                    Button { model.queryChanged("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.60))
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
                }
            }
                .padding(.leading, 22).padding(.trailing, 16)
                .frame(maxWidth: 720).frame(height: 56)
                .modifier(SearchSurface())
                .padding(.horizontal, 52)
            HStack {
                Spacer()
                Button { model.showSettings?() } label: { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).accessibilityLabel("Moonshine Settings").help("Settings (⌘,)")
            }.foregroundStyle(.white.opacity(0.55))
        }.padding(.horizontal, 46).padding(.bottom, 22)
    }
    private var previewCanvas: some View {
        let layout = model.layout
        let items = Dictionary(uniqueKeysWithValues: model.mainItems.map { ($0.id, $0) })
        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.tiles) { tile in
                        if let item = items[tile.id] {
                            // Keep tile layout fixed. Only its composited scale/offset
                            // changes during exposure, so text, clipping and shadows do
                            // not have to resize on every animation frame.
                            let source = !reduceMotion && model.previews[item.id] != nil ? model.sourceFrame(for: item) : nil
                            let zoom = source.map {
                                WindowZoom(source: CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: max(1, $0.height - 36)),
                                           tile: tile.frame, aspectRatio: item.aspectRatio ?? 1.5)
                            } ?? .identity
                            previewTile(item, size: tile.frame.size)
                                .frame(width: tile.frame.width, height: tile.frame.height)
                                .compositingGroup()
                                .scaleEffect(model.spread ? 1 : zoom.scale, anchor: .topLeading)
                                .offset(model.spread ? .zero : zoom.offset)
                                .position(x: tile.frame.midX, y: tile.frame.midY)
                                .opacity(model.spread || source != nil ? 1 : 0)
                                .zIndex(model.search.selectedID == item.id && model.isClosing ? 1 : -Double(item.recency ?? 999) / 1000)
                                .id(item.id)
                                .transition(.opacity)
                        }
                    }
                }.frame(width: model.canvasSize.width, height: layout.height, alignment: .topLeading)
                    .animation(reduceMotion || model.isSettling ? nil : .easeOut(duration: 0.14), value: model.mainItems.map(\.id))
            }.scrollIndicators(.hidden).scrollClipDisabled(!model.spread || model.isSettling)
                .accessibilityLabel(model.search.isSearching ? "Plausible windows and tabs" : model.browsingTabs ? "Browser tabs" : "Window overview")
                .overlay { if model.mainItems.isEmpty { emptyCanvas } }
                .onChange(of: model.search.selectedID) { _, id in
                    if !model.pointerHasMoved, let id, items[id] != nil { proxy.scrollTo(id) }
                }
                .onChange(of: model.presentationID) { _, _ in
                    if let id = layout.tiles.first?.id { proxy.scrollTo(id, anchor: .top) }
                }
        }
    }
    private var emptyCanvas: some View {
        VStack(spacing: 14) {
            if model.isRefining { ProgressView().controlSize(.small) }
            else { Image(systemName: "magnifyingglass").font(.system(size: 29, weight: .light)).foregroundStyle(.white.opacity(0.45)) }
            Text(model.isRefining ? "Looking for plausible matches…" : model.search.isSearching ? "No likely matches" : "No windows available")
                .font(.system(size: 19, weight: .medium))
            if model.search.isSearching {
                Text("Try another description, or return to everything open.").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Show everything") { model.showTabs(false) }.buttonStyle(.link)
            } else { Button("Set up access") { model.showSettings?() }.buttonStyle(.link) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func previewTile(_ item: WorkspaceItem, size: CGSize) -> some View {
        let selected = model.search.selectedID == item.id
        return Button { model.activate(item.id) } label: {
            Group {
                if item.kind == .browserTab { tabCard(item, size: size, selected: selected) }
                else { windowTile(item, size: size, selected: selected) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onContinuousHover { phase in if case .active = phase, model.pointerHasMoved { model.select(item.id) } }
            .accessibilityLabel("\(displayTitle(item)), \(item.app), \(item.kind == .browserTab ? "browser tab" : "window"), \(item.domain), \(item.context)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help([displayTitle(item), item.app + " · " + item.context, item.url ?? (model.previews[item.id] == nil ? "Preview unavailable" : "Cached local preview")].joined(separator: "\n"))
    }
    private func windowTile(_ item: WorkspaceItem, size: CGSize, selected: Bool) -> some View {
        let previewHeight = max(1, size.height - 36)
        return VStack(spacing: 8) {
            ZStack {
                if let preview = model.previews[item.id] {
                    Image(nsImage: preview).resizable().scaledToFit()
                } else {
                    // No picture to show: the app icon identifies it; hover help says why.
                    ZStack { Color(white: 0.16); appIcon(item, size: min(72, previewHeight * 0.45)) }
                }
            }
            .frame(width: size.width, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Self.accent : Color.white.opacity(0.17), lineWidth: selected ? 3 : 0.7).opacity(model.spread ? 1 : 0))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 7)
            HStack(spacing: 6) {
                appIcon(item, size: 19)
                Text(displayTitle(item)).font(.system(size: size.width < 200 ? 11 : 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }.padding(.horizontal, 8).padding(.vertical, 4)
                .background(selected ? Color.black.opacity(0.70) : Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
                .frame(height: 28).opacity(model.spread ? 1 : 0)
        }
    }
    /// Tabs carry no screenshot, so they are compact cards rather than empty window-sized boxes.
    private func tabCard(_ item: WorkspaceItem, size: CGSize, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                appIcon(item, size: 16)
                Text(item.domain.isEmpty ? item.app : item.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(displayTitle(item)).font(.system(size: size.width < 200 ? 12 : 14, weight: .medium))
                .lineLimit(size.height < 120 ? 2 : 3).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if size.height >= 100 { Text(item.context).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
        }.padding(12).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black.opacity(selected ? 0.66 : 0.40), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Self.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 0.7))
    }
    private static let accent = Color(red: 0.33, green: 0.67, blue: 1)
    private var browserShelf: some View {
        let tabs = Array(model.shelfItems.enumerated())
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Browser tabs").font(.system(size: 12, weight: .medium))
                Text("\(model.allTabs.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("View all tabs") { model.showTabs(true) }.buttonStyle(.link).font(.system(size: 11))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(tabs, id: \.element.id) { index, item in
                            // A thin rule wherever the browser window changes.
                            if index > 0, tabs[index - 1].element.app + tabs[index - 1].element.context != item.app + item.context {
                                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 26).padding(.horizontal, 4).accessibilityHidden(true)
                            }
                            shelfTab(item).id(item.id)
                        }
                    }.padding(3)
                }.scrollIndicators(.hidden)
                    .accessibilityLabel("Browser tab strip")
                    .onChange(of: model.search.selectedID) { _, id in
                        if !model.pointerHasMoved, let id, model.shelfItems.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.presentationID) { _, _ in
                        if let id = tabs.first?.element.id { proxy.scrollTo(id, anchor: .leading) }
                    }
            }.frame(height: 52)
        }
    }
    private func shelfTab(_ item: WorkspaceItem) -> some View {
        let selected = model.search.selectedID == item.id
        return Button { model.activate(item.id) } label: {
            HStack(spacing: 9) {
                appIcon(item, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(item)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.domain.isEmpty ? item.context : item.domain).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(width: 220, height: 46, alignment: .leading)
                .background(Color.black.opacity(selected ? 0.66 : 0.36), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Self.accent : Color.white.opacity(0.14), lineWidth: selected ? 2 : 0.6))
        }.buttonStyle(.plain)
            .onContinuousHover { phase in if case .active = phase, model.pointerHasMoved { model.select(item.id) } }
            .accessibilityLabel("\(displayTitle(item)), \(item.app) tab, \(item.domain), \(item.context)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help([displayTitle(item), item.app + " · " + item.context, item.url ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
    /// One line: what is selected on the left, how much there is and the keys on the right.
    /// Timings live in Settings → Diagnostics; status appears only when it is a caveat.
    private var footer: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                HStack { Text(notice).lineLimit(2); Button("Settings") { model.showSettings?() } }
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                if let item = model.search.selected, model.selectableIDs.contains(item.id) {
                    Text([displayTitle(item), item.app, item.context, item.url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(0.78))
                    if item.kind == .browserTab {
                        Button(item.pageContext?.validated(for: item.url) == nil ? "Title & URL only" : "Page context") { inspectingContext = true }
                            .buttonStyle(.link).accessibilityLabel("Inspect context for \(displayTitle(item))")
                            .popover(isPresented: $inspectingContext) { PageContextDetails(item: item, enabled: model.pageContextEnabled) }
                    }
                } else if model.search.explicitSelection {
                    Text("Selection is no longer available in these results. Choose another item.")
                }
                Spacer(minLength: 12)
                if model.isRefining { ProgressView().controlSize(.mini).help("Refining with Decisions") }
                if let caveat { Text(caveat).lineLimit(1) }
                if model.browsingTabs { Button("← Windows") { model.showTabs(false) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.78)) }
                Text(summary).lineLimit(1)
                Button("Tab → Spleen") { model.switchSearch?() }
                    .buttonStyle(.plain).help("Continue this search in Spleen")
                Text("↵ open    esc close")
            }.font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 18)
        }.padding(.horizontal, 48).padding(.top, 18)
    }
    private var summary: String {
        func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : (noun == "match" ? "es" : "s"))" }
        if model.search.isSearching { return count(model.matchingCount, "match") }
        if model.browsingTabs { return count(model.allTabs.count, "tab") }
        return model.allTabs.isEmpty ? count(model.windowItems.count, "window") : count(model.windowItems.count, "window") + " · " + count(model.allTabs.count, "tab")
    }
    private var caveat: String? {
        if model.demo { return model.liveDemo ? "Synthetic workspace · live Decisions" : "Synthetic workspace · activation disabled" }
        return model.search.isSearching && model.status.hasSuffix("unavailable") ? model.status : nil
    }
    private func displayTitle(_ item: WorkspaceItem) -> String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled \(item.kind == .window ? "window" : "tab")" : item.title
    }
    @ViewBuilder private func appIcon(_ item: WorkspaceItem, size: CGFloat) -> some View {
        if let icon = AppIcons.image(bundleID: item.bundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size).accessibilityHidden(true)
        } else { Image(systemName: item.kind == .browserTab ? "globe" : "macwindow").font(.system(size: size * 0.85)).frame(width: size, height: size).foregroundStyle(.secondary).accessibilityHidden(true) }
    }
}

private struct PageContextDetails: View {
    let item: WorkspaceItem
    let enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Moonshine knows").font(.headline)
            Text(item.title).font(.subheadline).textSelection(.enabled)
            Text(item.inferenceURL ?? item.app).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if let page = item.pageContext?.validated(for: item.url) {
                Text(enabled ? "These page labels are included in matching. Decisions receives them when refinement is on." : "Page context is available locally. Turn on Use page context in Settings to include it in matching and Decisions.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !page.siteName.isEmpty { detail("Site", page.siteName) }
                        if !page.summary.isEmpty { detail("Page description", page.summary) }
                        if !page.headings.isEmpty { detail("Headings", page.headings.joined(separator: " · ")) }
                        if !page.controls.isEmpty { detail("Control labels", page.controls.joined(separator: " · ")) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 280)
            } else {
                Text("Only the title, browser name, and URL are available. Enable this site in the Moonshine browser extension to add its page description, headings, and button labels. Restricted pages and PDFs may provide no extra context.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 390)
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

@MainActor private enum AppIcons {
    static var cache: [String: NSImage] = [:]
    static var unavailable = Set<String>()
    static func image(bundleID: String) -> NSImage? {
        if let image = cache[bundleID] { return image }
        guard !unavailable.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { unavailable.insert(bundleID); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path); cache[bundleID] = image; return image
    }
}

/// The search shares Spleen's generous glass capsule, with Moonshine's cool accent.
private struct SearchSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(.white.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.20), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color(white: 0.35).opacity(0.40)), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        }
    }
}

/// An AppKit editor keeps native composition, selection, and Edit menu commands.
struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    var ready: (NSTextField) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 20); field.controlSize = .large
        field.isEditable = true; field.isSelectable = true
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.textColor = .white.withAlphaComponent(0.94)
        field.placeholderAttributedString = NSAttributedString(string: "Search windows and tabs…", attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ])
        field.appearance = NSAppearance(named: .darkAqua)
        field.focusRingType = .none; field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilitySubrole(.searchField)
        field.setAccessibilityLabel("Search your open workspace")
        DispatchQueue.main.async { ready(field) }
        return field
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        context.coordinator.parent = self
        if view.stringValue != text, !((view.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) { view.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        init(_ parent: SearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
    }
}
