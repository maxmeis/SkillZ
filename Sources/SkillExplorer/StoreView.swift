import SwiftUI

struct CatalogSkill: Decodable, Identifiable {
    let id: String
    let source: String
    let skillId: String
    let name: String
    let installs: Int

    var webURL: URL { URL(string: "https://www.skills.sh/")!.appendingPathComponent(id) }

    var canInstall: Bool {
        source.split(separator: "/").count == 2
            && source.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_.-]*\/[A-Za-z0-9_][A-Za-z0-9_.-]*/) != nil
            && skillId.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_.-]*/) != nil
    }
}

enum SkillCatalog {
    private struct Response: Decodable { let skills: [CatalogSkill] }

    static func search(_ query: String) async throws -> [CatalogSkill] {
        var url = URLComponents(string: "https://www.skills.sh/api/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "30")]
        let (data, response) = try await URLSession.shared.data(from: url.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).skills
    }

    static func install(_ skill: CatalogSkill) throws -> String {
        guard skill.canInstall else { throw CocoaError(.fileWriteInvalidFileName) }
        let occupied = Entry.userSkillRoots.contains { root in
            let folder = Entry.home.appendingPathComponent(root.path).appendingPathComponent(skill.skillId)
            return FileManager.default.fileExists(atPath: folder.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil
        }
        guard !occupied else { throw CocoaError(.fileWriteFileExists) }

        let fm = FileManager.default
        let home = Entry.home.path
        let paths = ["\(home)/.volta/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let npx = paths.map({ $0 + "/npx" }).first(where: fm.isExecutableFile(atPath:)) else {
            throw CocoaError(.executableNotLoadable, userInfo: [
                NSLocalizedDescriptionKey: "The app could not find npx. Install Node.js to install skills."
            ])
        }
        let log = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard fm.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.currentDirectoryURL = Entry.home
        process.arguments = ["--yes", "skills@1.9.0", "add", skill.source, "--skill", skill.skillId,
                             "--global", "--agent", "codex", "claude-code", "cursor", "--yes"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = paths.joined(separator: ":")
        environment["DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let installed = Entry.userSkillRoots.contains { root in
            let manifest = Entry.home.appendingPathComponent(root.path)
                .appendingPathComponent(skill.skillId).appendingPathComponent("SKILL.md")
            return fm.isReadableFile(atPath: manifest.path)
        }
        guard process.terminationStatus == 0, installed else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "Installation failed." : String(message.suffix(1600))
            ])
        }
        return message
    }
}

struct StoreView: View {
    let installedNames: Set<String>
    let onInstall: () -> Void
    @State private var query = ""
    @State private var results: [CatalogSkill] = []
    @State private var pending: CatalogSkill?
    @State private var busy = false
    @State private var status: String?
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skill Store").font(.title2.bold())
                Spacer()
                Link("skills.sh", destination: URL(string: "https://www.skills.sh/")!)
            }
            HStack {
                TextField("Search skills.sh", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", systemImage: "magnifyingglass", action: search)
                    .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            if busy { ProgressView().controlSize(.small) }
            if let status { Text(status).font(.callout).textSelection(.enabled) }
            if results.isEmpty && !busy && status == nil {
                ContentUnavailableView(searched ? "No results" : "Discover skills", systemImage: "magnifyingglass",
                                       description: Text(searched ? "Try a different search term." : "Search for a skill or task."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { skill in
                            HStack {
                                VStack(alignment: .leading) {
                                    Link(skill.name, destination: skill.webURL).font(.headline)
                                    Text(skill.source).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(skill.installs, format: .number).foregroundStyle(.secondary)
                                    .help("Installs reported by skills.sh")
                                if installedNames.contains(skill.skillId.lowercased()) {
                                    Text("Name exists locally").foregroundStyle(.secondary)
                                } else {
                                    Button("Install") { pending = skill }
                                        .accessibilityLabel("Install \(skill.name) from \(skill.source)")
                                        .disabled(busy || !skill.canInstall)
                                }
                            }.padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert("Install skill globally?", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ), presenting: pending) { skill in
                Button("Install") { install(skill) }
                Button("Cancel", role: .cancel) {}
            } message: { skill in
                Text("Install \(skill.name) from \(skill.source) for Codex, Claude Code, and Cursor. OMP can find the shared copy in your home directory.")
            }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, term.count >= 2 else { return }
        busy = true
        status = nil
        Task {
            defer { busy = false; searched = true }
            do { results = try await SkillCatalog.search(term) }
            catch { status = "Search failed: \(error.localizedDescription)" }
        }
    }

    private func install(_ skill: CatalogSkill) {
        guard !busy else { return }
        busy = true
        status = nil
        Task {
            defer { busy = false }
            do {
                _ = try await Task.detached { try SkillCatalog.install(skill) }.value
                onInstall()
                status = "\(skill.name) was installed."
            } catch {
                onInstall()
                status = error.localizedDescription
            }
        }
    }
}

struct CatalogMatchView: View {
    let name: String
    @State private var matches: [CatalogSkill]?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let matches {
                Text(matches.isEmpty ? "No matching name on skills.sh" : "Matching names on skills.sh")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(matches) { skill in
                    Link(skill.source, destination: skill.webURL).font(.caption)
                }
            } else {
                Button(failed ? "Check the catalog again" : "Check skills.sh", systemImage: "magnifyingglass") {
                    loading = true
                    Task {
                        defer { loading = false }
                        do {
                            matches = try await SkillCatalog.search(name).filter {
                                $0.skillId.caseInsensitiveCompare(name) == .orderedSame
                            }
                        } catch { failed = true }
                    }
                }.disabled(loading)
            }
        }
    }
}
