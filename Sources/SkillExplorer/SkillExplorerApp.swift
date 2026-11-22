import SwiftUI
import AppKit

struct Entry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let source: String
    var linkTarget: URL? {
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path == url.path ? nil : resolved
    }
    var standard: Bool {
        [url, url.resolvingSymlinksInPath()].contains { location in
            let parts = location.pathComponents
            let claudeSync = parts.contains(".claude") && parts.contains("synced")
            return parts.contains(".system") || parts.contains(".kits")
                || (parts.contains("plugins") && parts.contains("cache")) || claudeSync
        }
    }
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let userSkillRoots: [(path: String, agents: [String])] = [
        (".agents/skills", ["Codex", "Cursor", "OMP"]),
        (".codex/skills", ["Codex", "Cursor"]),
        (".claude/skills", ["Claude", "Cursor"]),
        (".cursor/skills", ["Cursor"]),
        (".omp/agent/skills", ["OMP"]),
        (".pi/agent/skills", ["OMP"])
    ]
    var agents: [String] {
        guard url.lastPathComponent == "SKILL.md" else { return [] }
        let folder = url.deletingLastPathComponent().path
        for root in Self.userSkillRoots {
            let prefix = Self.home.path + "/" + root.path + "/"
            if folder.hasPrefix(prefix) {
                return Self.skillAgents(root.agents, relative: folder.dropFirst(prefix.count))
            }
        }
        return []
    }

    private static func skillAgents(_ agents: [String], relative: Substring) -> [String] {
        let parts = relative.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }),
              parts.first?.lowercased() != "synced" else { return [] }
        return parts.count == 1 ? agents : agents.filter { $0 != "OMP" }
    }
    var name: String { url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent }
}

struct SkillCard: Identifiable {
    let id: String
    let preferred: Entry
    let copies: [Entry]

    var name: String { preferred.name }
    var agents: [String] { Set(copies.flatMap { $0.agents }).sorted() }
    var standard: Bool { copies.allSatisfy { $0.standard } }
}

private struct SkillsLock: Decodable {
    struct Record: Decodable {
        let source: String
    }
    let skills: [String: Record]

    static func read() throws -> SkillsLock? {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let path = state.flatMap { $0.isEmpty ? nil : $0 }
        let file = path.map { URL(fileURLWithPath: $0).appendingPathComponent("skills/.skill-lock.json") }
            ?? Entry.home.appendingPathComponent(".agents/.skill-lock.json")
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}

struct FileNode: Identifiable {
    var id: URL { url }
    let url: URL
    let children: [FileNode]?
    let isLink: Bool
    let isReadable: Bool

    var icon: String {
        if isLink { return "link" }
        return children == nil ? "doc" : "folder"
    }

    static func contents(of folder: URL, ancestors: Set<String> = []) -> [FileNode] {
        let resolved = folder.resolvingSymlinksInPath()
        guard !ancestors.contains(resolved.path) else { return [] }
        let visited = ancestors.union([resolved.path])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: resolved, includingPropertiesForKeys: Array(keys)
        )) ?? []
        return urls.compactMap { item -> FileNode? in
            let url = folder.appendingPathComponent(item.lastPathComponent)
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let target = item.resolvingSymlinksInPath()
            let values = try? target.resourceValues(forKeys: keys)
            if values?.isDirectory == true, !visited.contains(target.path) {
                return FileNode(url: url, children: contents(of: url, ancestors: visited),
                                isLink: isLink, isReadable: false)
            }
            return FileNode(url: url, children: nil, isLink: isLink,
                            isReadable: values?.isRegularFile == true)
        }.sorted {
            if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

@MainActor final class Library: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var selected: Entry?
    @Published var skillFolder: URL?
    @Published var text: String?
    @Published var query = ""
    @Published var agentFilter: String?
    @Published var skillFiles: [FileNode] = []
    let agentNames = ["Codex", "Claude", "Cursor", "OMP"]
    var cards: [SkillCard] {
        let groups = Dictionary(grouping: entries.filter {
            $0.url.lastPathComponent == "SKILL.md"
        }, by: { $0.name.lowercased() })
        return groups.compactMap { id, copies in
            let ordered = copies.filter { !$0.standard } + copies.filter { $0.standard }
            guard let preferred = ordered.first(where: matchesFilters) else { return nil }
            return SkillCard(id: id, preferred: preferred, copies: ordered)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let instructionNames: Set<String> = [
        "AGENTS.MD", "AGENTS.OVERRIDE.MD", "CODEX.MD", "CLAUDE.MD",
        "CURSOR.MD", "OMP.MD", "RULE.MD", "RULES.MD", "SYSTEM.MD", "APPEND_SYSTEM.MD", "PROMPT.MD", ".CURSORRULES"
    ]

    struct PromptSource: Identifiable {
        let id: String
        let folders: [String]
        let guidance: String
        var documentation: URL? = nil
    }

    var promptSources: [PromptSource] {
        let home = Entry.home.path
        let env = ProcessInfo.processInfo.environment
        let codex = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.codex"
        let claude = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.claude"
        let omp = env["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.omp/agent"
        return [
            PromptSource(id: "Codex", folders: [codex], guidance: "Erwartet: AGENTS.md oder AGENTS.override.md"),
            PromptSource(id: "Claude", folders: [claude], guidance: "Erwartet: CLAUDE.md",
                         documentation: URL(string: "https://code.claude.com/docs/en/memory")),
            PromptSource(id: "Cursor", folders: ["\(home)/.cursor"],
                         guidance: "Globale User Rules findest du in Cursor Settings → Rules.",
                         documentation: URL(string: "https://cursor.com/docs/rules#user-rules")),
            PromptSource(id: "OMP", folders: [omp, "\(home)/.omp"],
                         guidance: "Erwartet: AGENTS.md, RULES.md, SYSTEM.md oder APPEND_SYSTEM.md",
                         documentation: URL(string: "https://github.com/can1357/oh-my-pi/blob/main/docs/context-files.md")),
            PromptSource(id: "Gemeinsam", folders: [home, "\(home)/.agents"], guidance: "Gemeinsame lokale Anweisungen")
        ]
    }

    private var globalInstructionFolders: [String] { promptSources.flatMap(\.folders) }

    func globalInstructions(for source: PromptSource) -> [Entry] {
        entries.filter {
            source.folders.contains($0.url.deletingLastPathComponent().path)
                && instructionNames.contains($0.url.lastPathComponent.uppercased())
        }
    }

    var prompts: [Entry] {
        let skillPaths = Set(entries.filter { $0.url.lastPathComponent == "SKILL.md" }.map { $0.url.path })
        return entries.filter { entry in
            guard entry.url.lastPathComponent != "SKILL.md", !entry.standard,
                  query.isEmpty || entry.url.path.localizedCaseInsensitiveContains(query) else { return false }
            var folder = entry.url.deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                if skillPaths.contains(folder.appendingPathComponent("SKILL.md").path) { return false }
                folder.deleteLastPathComponent()
            }
            return true
        }
    }

    @Published var activeSkill: SkillCard?
    @Published private var skillsLock: SkillsLock?
    @Published private var skillsLockUnreadable = false

    func skillsShStatus(_ skill: SkillCard) -> String {
        if skillsLockUnreadable { return "skills.sh · Installationsdatei nicht lesbar" }
        guard let skillsLock else { return "skills.sh · Keine lokale Installationsdatei" }
        let record = skill.copies.lazy.compactMap { skillsLock.skills[$0.name] }.first
        return record.map { "skills.sh · Lokaler Eintrag: \($0.source)" }
            ?? "skills.sh · Kein lokaler Eintrag"
    }

    func matchesFilters(_ entry: Entry) -> Bool {
        (agentFilter.map(entry.agents.contains) ?? true)
            && (query.isEmpty || ([entry.name, entry.url.path] + entry.agents)
                .joined(separator: " ").localizedCaseInsensitiveContains(query))
    }

    @Published var error: String?
    var roots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.agents", "\(home)/.codex", "\(home)/.claude", "\(home)/.cursor", "\(home)/.omp", "\(home)/.pi/agent/skills"] + (UserDefaults.standard.stringArray(forKey: "extraRoots") ?? [])
    }
    func scan() {
        do {
            skillsLock = try SkillsLock.read()
            skillsLockUnreadable = false
        } catch {
            skillsLock = nil
            skillsLockUnreadable = true
        }
        var found: [String: Entry] = [:]
        let fm = FileManager.default
        let ignoredDirectories: Set<String> = [
            "node_modules", ".git", ".build", ".tmp", ".staging", "sessions", "archived_sessions", "logs"
        ]
        for folder in globalInstructionFolders {
            let urls = (try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey]
            )) ?? []
            for url in urls where instructionNames.contains(url.lastPathComponent.uppercased()) {
                if (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    found[url.path] = Entry(url: url, source: folder)
                }
            }
        }
        for root in roots {
            guard let iterator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey], options: []) else { continue }
            for case let url as URL in iterator {
                let name = url.lastPathComponent
                let isMarketplace = name == "marketplaces" && url.deletingLastPathComponent().lastPathComponent == "plugins"
                let isClaudeSync = url.path == Entry.home.appendingPathComponent(".claude/skills/synced").path
                if ignoredDirectories.contains(name) || isMarketplace || isClaudeSync {
                    iterator.skipDescendants()
                    continue
                }
                let entry = Entry(url: url, source: root)
                if name == "SKILL.md" { continue }
                let special = instructionNames.contains(name.uppercased())
                let prompt = url.pathComponents.contains(where: { ["prompts", "agents", "rules", "commands"].contains($0) }) && ["md", "mdc", "txt"].contains(url.pathExtension)
                if special || prompt {
                    let target = url.resolvingSymlinksInPath()
                    if (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        found[url.path] = entry
                    }
                }
            }
        }
        func scanSkills(in folder: URL, source: String, ancestors: Set<String> = []) {
            let resolved = folder.resolvingSymlinksInPath()
            guard !ancestors.contains(resolved.path) else { return }
            let visited = ancestors.union([resolved.path])
            let manifest = folder.appendingPathComponent("SKILL.md")
            let entry = Entry(url: manifest, source: source)
            if !entry.agents.isEmpty, !entry.standard,
               (try? manifest.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found[manifest.path] = entry
                return
            }
            let children = (try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children where child.lastPathComponent.lowercased() != "synced" {
                if (try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    scanSkills(in: folder.appendingPathComponent(child.lastPathComponent), source: source, ancestors: visited)
                }
            }
        }
        for root in Entry.userSkillRoots {
            let folder = Entry.home.appendingPathComponent(root.path)
            scanSkills(in: folder, source: folder.path)
        }
        entries = found.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
    func select(_ entry: Entry) {
        open(entry)
    }
    func openSkill(_ card: SkillCard) {
        let previous = activeSkill
        activeSkill = card
        open(card.preferred)
        if selected != card.preferred { activeSkill = previous }
    }

    func closeDetail() {
        selected = nil
        activeSkill = nil
        skillFolder = nil
        skillFiles = []
        text = nil
    }

    func trashSkill(_ skill: SkillCard) {
        let fm = FileManager.default
        let folders = skill.copies.map { $0.url.deletingLastPathComponent() }
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = staging.appendingPathComponent(skill.name)
        let archive = staging.appendingPathComponent("\(skill.name).zip")
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            for (index, folder) in folders.enumerated() {
                let manifest = folder.appendingPathComponent("SKILL.md")
                let entry = Entry(url: manifest, source: folder.path)
                guard !entry.agents.isEmpty, !entry.standard,
                      (try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                      (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                      (try manifest.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let copy = backup.appendingPathComponent("\(index + 1)-\(folder.lastPathComponent)")
                try fm.copyItem(at: folder, to: copy)
                if (try manifest.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                    let archivedManifest = copy.appendingPathComponent("SKILL.md")
                    try fm.removeItem(at: archivedManifest)
                    try fm.copyItem(at: manifest.resolvingSymlinksInPath(), to: archivedManifest)
                }
            }
            let locations = folders.enumerated().map { "\($0.offset + 1)-\($0.element.lastPathComponent): \($0.element.path)" }
            try locations.joined(separator: "\n").write(
                to: backup.appendingPathComponent("original-paths.txt"), atomically: true, encoding: .utf8
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", backup.path, archive.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            try fm.trashItem(at: archive, resultingItemURL: nil)
        } catch {
            self.error = "Das ZIP konnte nicht in den Papierkorb gelegt werden. Die Skill-Ordner wurden nicht entfernt. \(error.localizedDescription)"
            return
        }
        do {
            for folder in folders {
                try fm.trashItem(at: folder, resultingItemURL: nil)
            }
        } catch {
            self.error = "Ein Ordner konnte nicht entfernt werden. Das vollständige ZIP liegt im Papierkorb. \(error.localizedDescription)"
        }
        closeDetail()
        scan()
    }

    func open(_ entry: Entry) {
        do {
            let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
            let value = data.contains(0) ? nil : String(data: data, encoding: .utf8)
            if entry.url.lastPathComponent == "SKILL.md",
               skillFolder == nil || activeSkill?.copies.contains(entry) == true {
                let folder = entry.url.deletingLastPathComponent()
                if skillFolder != folder {
                    skillFolder = folder
                    skillFiles = FileNode.contents(of: folder)
                }
            }
            selected = entry
            text = value
        } catch {
            self.error = error.localizedDescription
        }
    }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            var paths = UserDefaults.standard.stringArray(forKey: "extraRoots") ?? []
            if !paths.contains(url.path) { paths.append(url.path) }
            UserDefaults.standard.set(paths, forKey: "extraRoots"); scan()
        }
    }
}

struct ContentView: View {
    @StateObject var library = Library()
    private enum SectionTab: String, CaseIterable, Identifiable {
        case masterprompts = "Masterprompts"
        case skills = "Skills"
        case store = "Store"
        case mcp = "MCP"

        var id: Self { self }
    }

    @State private var section: SectionTab = .skills
    private var showPrompts: Bool { section == .masterprompts }
    @State private var showRemoveSkill = false

    private func switchSection(to target: SectionTab) {
        guard section != target else { return }
        section = target
        library.closeDetail()
        library.query = ""
        selectFirstSkill()
    }

    private func isMarkdown(_ entry: Entry) -> Bool {
        ["md", "markdown", "mdc"].contains(entry.url.pathExtension.lowercased())
    }

    @ViewBuilder private func fileContent(_ entry: Entry) -> some View {
        if let text = library.text {
            if isMarkdown(entry) {
                MarkdownReader(source: text).id(entry.id)
            } else {
                ScrollView {
                    Text(verbatim: text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.id(entry.id)
            }
        } else {
            ContentUnavailableView("Keine Textvorschau", systemImage: "doc",
                                   description: Text("Öffne die Datei in der Standard-App."))
        }
    }
    private var masterprompts: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Globale Anweisungen").font(.headline).padding(.top, 12)
                TextField("Name, Agent oder Pfad suchen", text: $library.query).textFieldStyle(.roundedBorder)
                List {
                    ForEach(library.promptSources) { source in
                        let entries = library.globalInstructions(for: source)
                        let matches = entries.filter {
                            library.query.isEmpty || source.id.localizedCaseInsensitiveContains(library.query)
                                || $0.url.path.localizedCaseInsensitiveContains(library.query)
                        }
                        if library.query.isEmpty || source.id.localizedCaseInsensitiveContains(library.query) || !matches.isEmpty {
                            Section {
                                ForEach(matches) { prompt in
                                    Button { library.select(prompt) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(prompt.name).font(.body.weight(.medium))
                                            Text((prompt.url.path as NSString).abbreviatingWithTildeInPath)
                                                .font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 4).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .listRowBackground(library.selected == prompt ? Color.accentColor.opacity(0.14) : Color.clear)
                                }
                                if entries.isEmpty && source.id != "Gemeinsam" {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Keine lokale Datei gefunden").font(.callout)
                                        Text(source.guidance).font(.caption).foregroundStyle(.secondary)
                                        if source.id != "Cursor", let folder = source.folders.first {
                                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                        if let docs = source.documentation {
                                            Link("Dokumentation", destination: docs).font(.caption)
                                        }
                                    }.padding(.vertical, 4)
                                }
                            } header: {
                                Label { Text(source.id) } icon: {
                                    if source.id == "Gemeinsam" { Image(systemName: "folder") }
                                    else { agentIcon(source.id).resizable().scaledToFit().frame(width: 17, height: 17) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.thinMaterial)

            Divider()

            if let entry = library.selected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(entry.name).font(.headline)
                        Spacer()
                        Button("In Standard-App öffnen", systemImage: "arrow.up.right.square") {
                            if !NSWorkspace.shared.open(entry.url) { library.error = "macOS konnte die Datei nicht öffnen." }
                        }
                    }
                    Divider()
                    fileContent(entry)
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Anweisung auswählen", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor private static let brandIcons: [String: NSImage] = {
        let bundle = Bundle.main.url(forResource: "AgentIcons", withExtension: nil) != nil
            ? Bundle.main : Bundle.module
        return Dictionary(uniqueKeysWithValues: ["Codex", "Claude", "Cursor", "OMP"].compactMap { agent in
            guard let url = bundle.url(forResource: agent, withExtension: "png", subdirectory: "AgentIcons"),
                  let icon = NSImage(contentsOf: url) else { return nil }
            return (agent, icon)
        })
    }()

    private func agentIcon(_ agent: String) -> Image {
        if let image = Self.brandIcons[agent] { return Image(nsImage: image) }
        return Image(systemName: "questionmark.circle")
    }

    private func agentBadges(_ agents: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(agents.isEmpty ? ["Unbekannt"] : agents, id: \.self) { agent in
                Label { Text(agent) } icon: { agentIcon(agent).resizable().scaledToFit().frame(width: 16, height: 16) }
                    .font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }

    private func selectFirstSkill() {
        guard section == .skills, library.selected == nil, let first = library.cards.first else { return }
        library.openSkill(first)
    }

    private var sectionHeader: some View {
        HStack {
            Spacer()
            Picker("Bereich", selection: Binding(get: { section }, set: { target in
                switchSection(to: target)
            })) {
                Text("Masterprompts").tag(SectionTab.masterprompts)
                Text("Skills").tag(SectionTab.skills)
                Text("Store").tag(SectionTab.store)
                Text("MCP").tag(SectionTab.mcp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 415)
            Spacer()
        }.padding(.vertical, 10).background(.bar)
    }

    private var skillSidebar: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Skills").font(.headline)
                Spacer()
                Text(library.cards.count, format: .number)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.top, 12)
            TextField("Skills suchen", text: $library.query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            Picker("Agent", selection: $library.agentFilter) {
                Text("Alle Agenten").tag(nil as String?)
                ForEach(library.agentNames, id: \.self) { agent in
                    Label { Text(agent) } icon: { agentIcon(agent).resizable().scaledToFit().frame(width: 16, height: 16) }
                        .tag(Optional(agent))
                }
            }.labelsHidden().padding(.horizontal, 12)
            List(library.cards) { card in
                Button {
                    guard card.id != library.activeSkill?.id else { return }
                    library.openSkill(card)
                } label: {
                    HStack(spacing: 6) {
                        Text(card.name)
                            .foregroundStyle(.primary)
                            .fontWeight(card.id == library.activeSkill?.id ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        ForEach(library.agentNames.filter { card.agents.contains($0) }, id: \.self) { agent in
                            agentIcon(agent).resizable().scaledToFit()
                                .frame(width: 17, height: 17)
                                .help(agent)
                                .accessibilityLabel(agent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .listRowBackground(card.id == library.activeSkill?.id ? Color.accentColor.opacity(0.14) : Color.clear)
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        }.background(.thinMaterial).frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
    }

    private func skillPreview(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack {
            Text(entry.url.lastPathComponent).font(.headline).lineLimit(1)
            Spacer()
            Button("In Standard-App öffnen", systemImage: "arrow.up.right.square") {
                if !NSWorkspace.shared.open(entry.url) {
                    library.error = "macOS konnte die Datei nicht öffnen."
                }
            }.keyboardShortcut(.return, modifiers: .command)
            Button("Im Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            .labelStyle(.iconOnly)
            .help("Im Finder zeigen")
        }.padding(12)
            Divider()
            fileContent(entry)
        }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileNavigator(_ skill: SkillCard, entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dateien", systemImage: "folder").font(.headline)
                Spacer()
                Menu {
                    Button("Skill entfernen", systemImage: "trash", role: .destructive) {
                        showRemoveSkill = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Skill-Aktionen")
            }
            Text(skill.copies.count == 1 ? "Speicherort" : "\(skill.copies.count) Speicherorte")
                .font(.subheadline.bold())
            ForEach(skill.copies) { copy in
                let folder = copy.url.deletingLastPathComponent()
                let isCurrent = folder == library.skillFolder
                Button {
                    if !isCurrent { library.select(copy) }
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "folder")
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(.caption, design: .monospaced))
                            if let target = copy.linkTarget {
                                Label((target.path as NSString).abbreviatingWithTildeInPath, systemImage: "link")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folder.path)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
            if skill.copies.count > 1 {
                let targets = Set(skill.copies.map { ($0.linkTarget ?? $0.url).path })
                Text(targets.count == 1 ? "Verknüpft · dieselbe Datei" : "Unterschiedliche Dateien")
                    .font(.caption).foregroundStyle(.secondary)
            }
            agentBadges(skill.agents)
                .help("Mögliche Agenten für alle Kopien dieses Skills")
            Text(library.skillsShStatus(skill)).font(.caption).foregroundStyle(.secondary)
            CatalogMatchView(name: skill.name).id(skill.id)
            Divider()
            Text(skill.name).font(.subheadline.bold())
            List {
                OutlineGroup(library.skillFiles, children: \.children) { node in
                    if node.children != nil {
                        Label(node.url.lastPathComponent, systemImage: node.icon)
                    } else {
                        Button {
                            if node.url != entry.url {
                                library.select(Entry(url: node.url, source: entry.source))
                            }
                        } label: {
                            Label(node.url.lastPathComponent, systemImage: node.icon)
                                .fontWeight(node.url == entry.url ? .bold : .regular)
                        }.buttonStyle(.plain)
                            .disabled(!node.isReadable)
                            .help(node.isLink ? node.url.resolvingSymlinksInPath().path : node.url.path)
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        }.padding(12).background(.thinMaterial).frame(minWidth: 265, idealWidth: 295, maxWidth: 355)
    }

    private var skillsWorkspace: some View {
        HSplitView {
            skillSidebar
            if let entry = library.selected {
                skillPreview(entry)
                if let skill = library.activeSkill { fileNavigator(skill, entry: entry) }
            } else {
                ContentUnavailableView("Kein Skill ausgewählt", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader.fixedSize(horizontal: false, vertical: true)
            Divider()
            GeometryReader { space in
                Group {
                    if section == .store {
                        StoreView(installedNames: Set(library.entries.filter {
                            $0.url.lastPathComponent == "SKILL.md"
                        }.map { $0.name.lowercased() }), onInstall: library.scan)
                    } else if section == .mcp {
                        MCPView()
                    } else if showPrompts {
                        masterprompts
                    } else {
                        skillsWorkspace
                    }
                }
                .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
            }
        }
        .toolbar {
            Button("Neu suchen", systemImage: "arrow.clockwise") { library.scan(); selectFirstSkill() }
        }
        .onAppear { library.scan(); selectFirstSkill() }
        .onChange(of: library.selected?.id) { _, _ in selectFirstSkill() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let entry = library.selected { library.open(entry) }
        }
        .alert("Skill in den Papierkorb legen?", isPresented: $showRemoveSkill, presenting: library.activeSkill) { skill in
            Button("In den Papierkorb", role: .destructive) { library.trashSkill(skill) }
            Button("Abbrechen", role: .cancel) {}
        } message: { skill in
            Text("Das ZIP und diese Ordner kommen in den Papierkorb:\n\n" + skill.copies.map {
                $0.url.deletingLastPathComponent().path
            }.joined(separator: "\n"))
        }
        .alert("Datei konnte nicht verarbeitet werden", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
        .frame(minWidth: 960, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@main struct SkillExplorerApp: App {
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1200, height: 760) }
}
