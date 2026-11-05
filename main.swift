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
let backspace: Int64 = 0x33, space: Int64 = 0x31, boundaries: Set<Int64> = [space, 0x24, 0x30]  // + return, tab
// The spell checker accepts any single letter, so one-letter words need an explicit list.
let oneLetterWords = ["ru": Set("авикосуяАВИКОСУЯ".map(String.init)), "en": ["a", "A", "I"]]
let vowels = ["ru": Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ"), "en": Set("aeiouyAEIOUY")]
let magic: Int64 = 0x50554E54  // marks our own synthetic events so the tap skips them

struct Key { let code: Int64; let shift: Bool }
var word: [Key] = []
var prev: (lang: String?, words: [[Key]]) = (nil, [])  // words just before `word`, same layout, not converted
var tap: CFMachPort?

func text(_ word: [Key], ru: Bool) -> String {
    word.map { k in
        let t = keys[k.code]!
        return ru ? (k.shift ? t.2.uppercased() : t.2) : (k.shift ? t.1 : t.0)
    }.joined()
}

func isWord(_ s: String, _ lang: String) -> Bool {
    if s.count == 1 { return oneLetterWords[lang]!.contains(s) }
    return NSSpellChecker.shared.checkSpelling(
        of: s, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
    ).location == NSNotFound
}

// The spell checker learns words typed often, so a long-mistyped "ghbdtn" can pass; no vowels still means wrong.
func looksWrong(_ s: String, _ lang: String) -> Bool {
    !isWord(s, lang) || (s.count > 1 && !s.contains(where: vowels[lang]!.contains))
}

// Converts only when the typed text looks wrong but the other layout's text is a word.
func converted(_ word: [Key], currentRu: Bool) -> String? {
    let cur = text(word, ru: currentRu), other = text(word, ru: !currentRu)
    return looksWrong(cur, currentRu ? "ru" : "en") && isWord(other, currentRu ? "en" : "ru") ? other : nil
}

// Fixes the word plus the words right before it that were typed in the same wrong layout,
// so "b ghbdtn" becomes "и привет". A lone short word is too ambiguous to fix on its own.
func fixPhrase(_ prev: [[Key]], _ word: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    guard word.count >= 2, let fix = converted(word, currentRu: ru) else { return nil }
    var words = [fix], erase = word.count
    for p in prev.reversed() {
        guard let f = converted(p, currentRu: ru) else { break }
        words.insert(f, at: 0)
        erase += p.count + 1  // + the space after it
    }
    return (erase, words.joined(separator: " "))
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
        if type == .leftMouseDown { word = []; prev.words = [] }  // caret moved, the buffer no longer matches the screen
        return pass
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
    if flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty, keys[code] != nil {
        word.append(Key(code: code, shift: flags.contains(.maskShift) != flags.contains(.maskAlphaShift)))
        return pass
    }
    if code == backspace, flags.intersection([.maskCommand, .maskAlternate]).isEmpty {
        if word.isEmpty { prev.words = [] } else { word.removeLast() }
        return pass
    }
    defer { word = [] }
    let current = lang(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    if prev.lang != current { prev = (current, []) }
    guard boundaries.contains(code), current == "ru" || current == "en" else { prev.words = []; return pass }
    guard let fix = fixPhrase(prev.words, word, currentRu: current == "ru") else {
        prev.words = code == space && !word.isEmpty ? Array((prev.words + [word]).suffix(5)) : []
        return pass
    }
    prev.words = []
    // Swallow the boundary key and replay it after the fix so the order on screen stays right.
    for _ in 0..<fix.erase { post(CGKeyCode(backspace)) }
    select(lang: current == "ru" ? "en" : "ru")
    for ch in fix.text { post(0, String(ch)) }  // one char per event: some apps drop longer unicode strings
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
    assert(fixPhrase([], typed("b"), currentRu: false) == nil)  // lone "и" is too ambiguous
    assert(fixPhrase([typed("b")], typed("ghbdtn"), currentRu: false)! == (8, "и привет"))
    assert(fixPhrase([typed("hello"), typed("d")], typed("ljvt"), currentRu: false)! == (6, "в доме"))
    print("selftest ok")
    exit(0)
}

final class Actions: NSObject {
    @objc func about() {
        let repo = "https://github.com/puchkoff/flipkey"
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's panel opens behind other windows otherwise
        NSApp.orderFrontStandardAboutPanel(options: [  // name, version and icon come from the .app bundle
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
let icon = Bundle.main.image(forResource: "MenuBarIcon")  // nil when run as a bare binary, not the .app
icon?.size = NSSize(width: 30, height: 18)
icon?.isTemplate = true  // macOS tints it for light and dark menu bars
item.button?.image = icon ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "flipkey")
item.menu = NSMenu()
item.menu?.addItem(withTitle: "About flipkey", action: #selector(Actions.about), keyEquivalent: "").target = actions
item.menu?.addItem(.separator())
item.menu?.addItem(withTitle: "Quit flipkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

// Accessibility access is needed for the key tap; wait for it without blocking, so the icon shows meanwhile.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(prompt)
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
    guard AXIsProcessTrusted() else { return }
    timer.invalidate()
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
    guard let tap else { print("Could not create the event tap."); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}
app.run()
