// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SkillExplorer", platforms: [.macOS(.v14)], products: [.executable(name: "SkillExplorer", targets: ["SkillExplorer"])], targets: [.executableTarget(name: "SkillExplorer", resources: [.copy("AgentIcons")])])
