import Cocoa
import Foundation

/// Tabela de nomes de tecla -> keycode virtual do macOS (layout ANSI).
enum KeyCodes {
    static let byName: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    ]

    static func code(for name: String) -> CGKeyCode? {
        byName[name.lowercased()]
    }

    static func name(for code: CGKeyCode) -> String {
        for (name, value) in byName where value == code {
            return name.count == 1 ? name.uppercased() : name
        }
        return "#\(code)"
    }
}

/// Combinação de teclas que libera a saída do modo quiosque.
struct ExitCombo {
    var keyCode: CGKeyCode = 12 // Q
    var command = true
    var control = true
    var option = true
    var shift = false

    /// Texto amigável, ex.: "⌃⌥⌘Q".
    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + KeyCodes.name(for: keyCode)
    }

    func matches(keyCode code: Int64, flags: CGEventFlags) -> Bool {
        guard CGKeyCode(truncatingIfNeeded: code) == keyCode else { return false }
        return modifiersMatch(
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift)
        )
    }

    func matches(event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        return modifiersMatch(event: event)
    }

    func modifiersMatch(event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        return modifiersMatch(
            command: flags.contains(.command),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift)
        )
    }

    func modifiersMatch(flags: CGEventFlags) -> Bool {
        modifiersMatch(
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift)
        )
    }

    private func modifiersMatch(command: Bool, control: Bool, option: Bool, shift: Bool) -> Bool {
        (!self.command || command)
            && (!self.control || control)
            && (!self.option || option)
            && (!self.shift || shift)
    }
}

struct Config {
    var url: URL
    var allowedHosts: [String]
    var exit: ExitCombo
    var holdSeconds: Double
    var blockForceQuit: Bool
    var blockSessionTermination: Bool

    static let defaultURLString = "https://tinyfingers.net/"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TinyFingersJail", isDirectory: true)
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// Lê `config.json` (criando um padrão na primeira execução) e aplica overrides de ambiente.
    static func load() -> Config {
        var config = Config(
            url: URL(string: defaultURLString)!,
            allowedHosts: [],
            exit: ExitCombo(),
            holdSeconds: 3.0,
            blockForceQuit: true,
            blockSessionTermination: false
        )

        let raw = readJSON() ?? [:]
        if raw.isEmpty {
            writeDefaultFile(config)
        }

        if let value = raw["url"] as? String, let url = URL(string: value), url.host != nil {
            config.url = url
        }
        if let hosts = raw["allowedHosts"] as? [String] {
            config.allowedHosts = hosts.map { $0.lowercased() }
        }
        if let seconds = raw["exitHoldSeconds"] as? Double {
            config.holdSeconds = seconds
        } else if let seconds = raw["exitHoldSeconds"] as? Int {
            config.holdSeconds = Double(seconds)
        }
        if let key = raw["exitKey"] as? String, let code = KeyCodes.code(for: key) {
            config.exit.keyCode = code
        }
        if let modifiers = raw["exitModifiers"] as? [String] {
            let set = Set(modifiers.map { $0.lowercased() })
            config.exit.command = set.contains("command") || set.contains("cmd")
            config.exit.control = set.contains("control") || set.contains("ctrl")
            config.exit.option = set.contains("option") || set.contains("alt")
            config.exit.shift = set.contains("shift")
        }
        if let value = raw["blockForceQuit"] as? Bool {
            config.blockForceQuit = value
        }
        if let value = raw["blockSessionTermination"] as? Bool {
            config.blockSessionTermination = value
        }

        // Overrides por variável de ambiente (úteis para testar sem editar o arquivo).
        let env = ProcessInfo.processInfo.environment
        if let value = env["TFJ_URL"], let url = URL(string: value), url.host != nil {
            config.url = url
        }
        if let value = env["TFJ_HOLD_SECONDS"], let seconds = Double(value) {
            config.holdSeconds = seconds
        }

        config.holdSeconds = min(max(config.holdSeconds, 0.5), 15)
        if !config.exit.command && !config.exit.control && !config.exit.option {
            // Nunca aceitar uma combinação sem modificadores: a criança acertaria sozinha.
            config.exit = ExitCombo()
        }

        var hosts = config.allowedHosts
        if let host = config.url.host?.lowercased() {
            hosts.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        config.allowedHosts = Array(Set(hosts))

        return config
    }

    /// A navegação só é liberada para o site configurado (e seus subdomínios).
    func allows(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func readJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeDefaultFile(_ config: Config) {
        let template: [String: Any] = [
            "url": defaultURLString,
            "allowedHosts": [String](),
            "exitKey": "q",
            "exitModifiers": ["control", "option", "command"],
            "exitHoldSeconds": config.holdSeconds,
            "blockForceQuit": config.blockForceQuit,
            "blockSessionTermination": config.blockSessionTermination,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
