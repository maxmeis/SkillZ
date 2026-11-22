# Skill Explorer

Native macOS-App mit SwiftUI und AppKit. Benötigt macOS 14 oder neuer.

## Start

Öffne `Package.swift` in Xcode. Starte das Ziel `SkillExplorer`.

Alternativ:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/skill-explorer-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/skill-explorer-swift swift run --disable-sandbox
```

Die App durchsucht `.agents`, `.codex`, `.claude` und `.cursor` im Benutzerordner. Füge weitere Projektordner mit „Ordner hinzufügen“ hinzu. Die App erkennt SKILL.md und lokale Anweisungsdateien. Sie erkennt auch Markdown- und Textdateien in Ordnern für Prompts, Agenten, Regeln und Befehle.

Wähle eine Datei zum Bearbeiten. Speichere mit ⌘S. Die App prüft vor dem Speichern, ob eine andere Anwendung die Datei geändert hat.

Die App zeigt lokale Dateien. Sie kann keine internen System-Prompts eines Anbieters lesen. Sie ermittelt keine tatsächlichen Ladevorgänge eines Agenten. Der Editor nutzt NSTextView mit nativer Textbearbeitung und Rückgängig-Funktion. Syntaxhervorhebung ist noch nicht enthalten.
