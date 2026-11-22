# SkillZ

SkillZ is a native macOS app for browsing agent skills, instructions, and MCP configurations. It uses SwiftUI and AppKit. It requires macOS 14 or later and a Swift 6 toolchain.

Run the app from the repository directory:

```sh
swift run SkillExplorer
```

You can also open `Package.swift` in Xcode and run the `SkillExplorer` target.

- **Skills** lists global user skills. Select a skill to see its files, locations, symbolic links, and agent badges. Use **Open in Default App** to edit a file.
- **Master Prompts** shows local global instructions for Codex, Claude, Cursor, and OMP when the files are present.
- **Store** searches skills.sh and can install a skill globally. Installation requires Node.js and `npx`.
- **MCP** shows local server configurations. Select a project to include its configuration files. The app does not check live connections.

When you remove a skill, the app first saves a ZIP archive to the macOS Trash. It then moves the skill folders to the Trash.
