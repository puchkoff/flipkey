// Watches typing and fixes words typed in the wrong layout (Russian <-> English), like Punto Switcher.
import Cocoa
import Carbon

// Keycode -> (English, English with Shift, Russian ЙЦУКЕН).
let keys: [Int64: (String, String, String)] = [
    0x0C: ("q", "Q", "й"), 0x0D: ("w", "W", "ц"), 0x0E: ("e", "E", "у"), 0x0F: ("r", "R", "к"),
    0x11: ("t", "T", "е"), 0x10: ("y", "Y", "н"), 0x20: ("u", "U", "г"), 0x22: ("i", "I", "ш"),
    0x1F: ("o", "O", "щ"), 0x23: ("p", "P", "з"), 0x21: ("[", "{", "х"), 0x1E: ("]", "}", "ъ"),
    0x00: ("a", "A", "ф"), 0x01: ("s", "S", "ы"), 0x02: ("d", "D", "в"), 0x03: ("f", "F", "а"),
    0x05: ("g", "G", "п"), 0x04: ("h", "H", "р"), 0x26: ("j", "J", "о"), 0x28: ("k", "K", "л"),
    0x25: ("l", "L", "д"), 0x29: (";", ":", "ж"), 0x27: ("'", "\"", "э"), 0x06: ("z", "Z", "я"),
    0x07: ("x", "X", "ч"), 0x08: ("c", "C", "с"), 0x09: ("v", "V", "м"), 0x0B: ("b", "B", "и"),
    0x2D: ("n", "N", "т"), 0x2E: ("m", "M", "ь"), 0x2B: (",", "<", "б"), 0x2F: (".", ">", "ю"),
]
let backspace: Int64 = 0x33, boundaries: Set<Int64> = [0x31, 0x24, 0x30]  // space, return, tab
let magic: Int64 = 0x50554E54  // marks our own synthetic events so the tap skips them

struct Key { let code: Int64; let shift: Bool }
var word: [Key] = []
var tap: CFMachPort?

func text(_ word: [Key], ru: Bool) -> String {
    word.map { k in
        let t = keys[k.code]!
        return ru ? (k.shift ? t.2.uppercased() : t.2) : (k.shift ? t.1 : t.0)
    }.joined()
}

func isWord(_ s: String, _ lang: String) -> Bool {
    NSSpellChecker.shared.checkSpelling(
        of: s, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
    ).location == NSNotFound
}

// Converts only when the typed text is not a word but the other layout's text is.
func converted(_ word: [Key], currentRu: Bool) -> String? {
    guard word.count >= 2 else { return nil }
    let cur = text(word, ru: currentRu), other = text(word, ru: !currentRu)
    return !isWord(cur, currentRu ? "ru" : "en") && isWord(other, currentRu ? "en" : "ru") ? other : nil
}

func lang(_ s: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages) else { return nil }
    return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String])?.first
}

func select(lang wanted: String) {
    let filter = [
        kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        kTISPropertyInputSourceIsSelectCapable as String: true,
    ] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    if let s = list.first(where: { lang($0) == wanted }) { TISSelectInputSource(s) }
}

func post(_ code: CGKeyCode, _ string: String? = nil) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = []
        if let string { e.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16)) }
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.post(tap: .cgSessionEventTap)
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return pass
    }
    guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != magic else {
        if type == .leftMouseDown { word = [] }  // caret moved, the buffer no longer matches the screen
        return pass
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
    if flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty, keys[code] != nil {
        word.append(Key(code: code, shift: flags.contains(.maskShift) != flags.contains(.maskAlphaShift)))
        return pass
    }
    if code == backspace, flags.intersection([.maskCommand, .maskAlternate]).isEmpty {
        if !word.isEmpty { word.removeLast() }
        return pass
    }
    defer { word = [] }
    let current = lang(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    guard boundaries.contains(code), current == "ru" || current == "en",
          let fix = converted(word, currentRu: current == "ru") else { return pass }
    // Swallow the boundary key and replay it after the fix so the order on screen stays right.
    for _ in word { post(CGKeyCode(backspace)) }
    select(lang: current == "ru" ? "en" : "ru")
    for ch in fix { post(0, String(ch)) }  // one char per event: some apps drop longer unicode strings
    post(CGKeyCode(code))
    return nil
}

if CommandLine.arguments.contains("--selftest") {
    let byChar = Dictionary(uniqueKeysWithValues: keys.map { ($0.value.0, $0.key) })
    let typed = { (en: String) in en.map { Key(code: byChar[String($0)]!, shift: false) } }
    assert(converted(typed("ghbdtn"), currentRu: false) == "привет")
    assert(converted(typed("hello"), currentRu: false) == nil)
    assert(converted(typed("hello"), currentRu: true) == "hello")  // typed as "руддщ"
    assert(converted(typed("vbh"), currentRu: true) == nil)  // "мир" is a real word
    print("selftest ok")
    exit(0)
}

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    print("Grant Accessibility access in System Settings > Privacy & Security, then run again.")
    exit(1)
}
let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                        eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
guard let tap else { print("Could not create the event tap."); exit(1) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
final class Actions: NSObject {
    @objc func about() {
        let repo = "https://github.com/puchkoff/flipkey"
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's panel opens behind other windows otherwise
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "flipkey",
            .applicationVersion: "0.1",
            .applicationIcon: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)!,
            .credits: NSAttributedString(
                string: "Fixes words typed in the wrong keyboard layout (Russian ⇄ English).\n\(repo)",
                attributes: [.link: URL(string: repo)!]),
        ])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
let actions = Actions()
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "flipkey")
item.menu = NSMenu()
item.menu?.addItem(withTitle: "About flipkey", action: #selector(Actions.about), keyEquivalent: "").target = actions
item.menu?.addItem(.separator())
item.menu?.addItem(withTitle: "Quit flipkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
app.run()
