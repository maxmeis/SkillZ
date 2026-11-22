import SwiftUI
import AppKit

struct MCPServerEntry: Identifiable {
    let agent: String
    let name: String
    let file: URL
    let enabled: Bool
    var id: String { "\(agent):\(file.path):\(name)" }
}

enum MCPInventory {
    static let agents = ["Codex", "Claude Code", "Claude Desktop", "Cursor", "OMP"]

    static func scan(project: URL?) -> [MCPServerEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        func directory(_ key: String, fallback: String) -> URL {
            if let value = env[key], !value.isEmpty { return URL(fileURLWithPath: value) }
            return home.appendingPathComponent(fallback)
        }

        let codex = directory("CODEX_HOME", fallback: ".codex")
        let claude = directory("CLAUDE_CONFIG_DIR", fallback: ".")
        let omp = directory("PI_CODING_AGENT_DIR", fallback: ".omp/agent")
        var files: [(String, URL)] = [
            ("Codex", codex.appendingPathComponent("config.toml")),
            ("Claude Code", claude.appendingPathComponent(".claude.json").standardizedFileURL),
            ("Claude Desktop", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
            ("Cursor", home.appendingPathComponent(".cursor/mcp.json")),
            ("OMP", omp.appendingPathComponent("mcp.json")),
            ("OMP", omp.appendingPathComponent(".mcp.json"))
        ]
        if let project {
            files += [
                ("Codex", project.appendingPathComponent(".codex/config.toml")),
                ("Claude Code", project.appendingPathComponent(".mcp.json")),
                ("Cursor", project.appendingPathComponent(".cursor/mcp.json")),
                ("OMP", project.appendingPathComponent(".omp/mcp.json")),
                ("OMP", project.appendingPathComponent(".omp/.mcp.json"))
            ]
        }
        var entries: [String: MCPServerEntry] = [:]
        for (agent, file) in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let servers = file.pathExtension == "toml" ? toml(data) : json(data)
            for (name, enabled) in servers {
                let entry = MCPServerEntry(agent: agent, name: name, file: file, enabled: enabled)
                entries[entry.id] = entry
            }
        }
        return entries.values.sorted {
            ($0.agent, $0.name.lowercased(), $0.file.path) < ($1.agent, $1.name.lowercased(), $1.file.path)
        }
    }

    static func json(_ data: Data) -> [String: Bool] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: [String: Any]] else { return [:] }
        let disabled = Set(root["disabledServers"] as? [String] ?? [])
        let enabled = Set(root["enabledServers"] as? [String] ?? [])
        return Dictionary(uniqueKeysWithValues: servers.map { name, config in
            let explicit = config["enabled"].map { !["false", "0"].contains(String(describing: $0).lowercased()) } ?? true
            let configured = !disabled.contains(name) && (explicit || enabled.contains(name))
                && config["disabled"] as? Bool != true
            return (name, configured)
        })
    }

    static func toml(_ data: Data) -> [String: Bool] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var servers: [String: Bool] = [:]
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                current = nil
                if let match = trimmed.firstMatch(of: /^\[\s*mcp_servers\s*\.\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_-]+))\s*\]\s*(?:#.*)?$/),
                   let name = match.1 ?? match.2 ?? match.3 {
                    current = String(name)
                    servers[String(name), default: true] = servers[String(name)] ?? true
                }
            } else if let current, trimmed.firstMatch(of: /^enabled\s*=\s*false\s*(?:#.*)?$/) != nil {
                servers[current] = false
            }
        }
        return servers
    }
}

struct MCPView: View {
    @State private var entries: [MCPServerEntry] = []
    @State private var project: URL?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP-Server").font(.title2.bold())
                Text(entries.count, format: .number).foregroundStyle(.secondary)
                Spacer()
                Button("Projekt auswählen", systemImage: "folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK { project = panel.url; reload() }
                }
                Button("Aktualisieren", systemImage: "arrow.clockwise", action: reload)
            }
            Text("Lokale Konfigurationen. Live-Verbindungen und Kontointegrationen werden hier nicht geprüft.")
                .font(.callout).foregroundStyle(.secondary)
            if let project {
                HStack {
                    Text(project.path).lineLimit(1).truncationMode(.middle)
                    Button("Projektfilter entfernen", systemImage: "xmark.circle") {
                        self.project = nil
                        reload()
                    }.labelStyle(.iconOnly)
                }.font(.caption).foregroundStyle(.secondary)
            }
            TextField("Server oder Agent suchen", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(MCPInventory.agents, id: \.self) { agent in
                    let matches = entries.filter {
                        $0.agent == agent && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                                              || agent.localizedCaseInsensitiveContains(query))
                    }
                    if query.isEmpty || !matches.isEmpty {
                        Section(agent) {
                            if matches.isEmpty {
                                Text("Keine lokalen Einträge gefunden").foregroundStyle(.secondary)
                            }
                            ForEach(matches) { server in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.name).font(.headline)
                                        Text((server.file.path as NSString).abbreviatingWithTildeInPath)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(server.enabled ? "Konfiguriert" : "Deaktiviert")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            }.scrollContentBackground(.hidden)
        }
        .padding(20)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: reload)
    }

    private func reload() { entries = MCPInventory.scan(project: project) }
}
