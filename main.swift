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
let backspace: Int64 = 0x33, returnKey: Int64 = 0x24, tabKey: Int64 = 0x30
// The spell checker accepts any single letter, so one-letter words need an explicit list.
let oneLetterWords = ["ru": Set("авикосуяАВИКОСУЯ".map(String.init)), "en": ["a", "A", "I"]]
let vowels = ["ru": Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ"), "en": Set("aeiouyAEIOUY")]
let magic: Int64 = 0x50554E54  // marks our own synthetic events so the tap skips them

struct Key { let code: Int64; let shift: Bool }
var word: [Key] = []
var prev: (lang: String?, words: [[Key]]) = (nil, [])  // words just before `word`, same layout, not converted
var tap: CFMachPort?
// Text typed after the word ("?", " ") is kept in `tail` so double Shift can erase and retype it.
var lastFix: (text: String, tail: String, lang: String)?  // what double Shift undoes
var lastWord: (keys: [Key], tail: String, lang: String, before: [[Key]])?  // last word left as typed; double Shift converts it
var shiftClean = false, shiftDown = Date.distantPast, lastShiftTap = Date.distantPast  // a "tap" is a quick Shift press with no other key in between
var sources: [String: TISInputSource] = [:]  // the layout last used for each language, so a fix switches back to it

// Character maps for retyping text in the other layout, e.g. "ghbdtn" <-> "привет".
let enToRu = Dictionary(uniqueKeysWithValues: keys.values.flatMap {
    [(Character($0.0), Character($0.2)), (Character($0.1), Character($0.2.uppercased()))]
})
let ruToEn = Dictionary(uniqueKeysWithValues: enToRu.map { ($1, $0) })
func swapLayout(_ s: String, toRu: Bool) -> String { String(s.map { (toRu ? enToRu : ruToEn)[$0] ?? $0 }) }

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

// The words right before a word, each followed by one space, that were typed in the same wrong layout,
// like "b" in "b ghbdtn". Returns how many characters they take and their fixed text, spaces included.
func wrongBefore(_ prev: [[Key]], currentRu ru: Bool) -> (erase: Int, text: String) {
    var text = "", erase = 0
    for p in prev.reversed() {
        guard let f = converted(p, currentRu: ru) else { break }
        text = f + " " + text
        erase += p.count + 1
    }
    return (erase, text)
}

// Fixes the word plus the words right before it that were typed in the same wrong layout,
// so "b ghbdtn" becomes "и привет". A lone short word is too ambiguous to fix on its own.
func fixPhrase(_ prev: [[Key]], _ word: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    var core = word, tail = ""
    while true {
        if core.count >= 2, let fix = converted(core, currentRu: ru) {
            let b = wrongBefore(prev, currentRu: ru)
            return (b.erase + word.count, b.text + fix + tail)
        }
        // In "ghbdtn," the comma key is the Russian "б" but was meant as punctuation; retry without it.
        guard !ru, let k = core.last, !Character(keys[k.code]!.0).isLetter else { return nil }
        tail = text([k], ru: false) + tail
        core.removeLast()
    }
}

func lang(_ s: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages) else { return nil }
    return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String])?.first
}

// The current layout's language; also remembers the layout, since a language can have several (ABC, U.S.).
func currentLang() -> String? {
    let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let l = lang(s)
    if let l { sources[l] = s }
    return l
}

func select(lang wanted: String) {
    if let s = sources[wanted] { TISSelectInputSource(s); return }
    let filter = [
        kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        kTISPropertyInputSourceIsSelectCapable as String: true,
    ] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    if let s = list.first(where: { lang($0) == wanted }) { TISSelectInputSource(s) }
}

func post(_ code: CGKeyCode, _ string: String? = nil, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        if let string { e.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16)) }
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.post(tap: .cgSessionEventTap)
    }
}

func typeText(_ s: String) {
    for ch in s {  // one char per event: some apps drop longer unicode strings
        switch ch {
        case "\n": post(CGKeyCode(returnKey))  // a typed newline character isn't Return in every app
        case "\t": post(CGKeyCode(tabKey))
        default: post(0, String(ch))
        }
    }
}

func erase(_ count: Int) { for _ in 0..<count { post(CGKeyCode(backspace)) } }

// The text a key event produces; empty or control characters for arrows, Escape and the like.
func printable(_ e: CGEvent) -> String? {
    var len = 0, buf = [UniChar](repeating: 0, count: 4)
    e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
    let s = String(utf16CodeUnits: buf, count: len)
    let ok = !s.isEmpty && s.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)  // arrows, F-keys
    }
    return ok ? s : nil
}

// Retypes the selection in the other layout. Reads it via Cmd+C, then puts the old clipboard back.
func convertSelection() {
    let pb = NSPasteboard.general, before = pb.changeCount
    let saved = (pb.pasteboardItems ?? []).map { item in  // every type, so images and rich text survive
        let copy = NSPasteboardItem()
        for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
        return copy
    }
    post(0x08, flags: .maskCommand)  // C
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard pb.changeCount != before else { return }  // nothing was selected
        defer { pb.clearContents(); pb.writeObjects(saved) }
        // shortcut: apps that copy the whole line with no selection (VS Code) get that line inserted; detect via AX if it bites.
        guard let sel = pb.string(forType: .string), !sel.isEmpty else { return }
        let toRu = !sel.contains { ruToEn[$0] != nil }
        typeText(swapLayout(sel, toRu: toRu))
        select(lang: toRu ? "ru" : "en")
    }
}

// Undo the last fix, else convert the word being typed or the last word, else convert the selection.
// The word takes along the short words before it typed in the same wrong layout, so "b pf" becomes "и за".
func onDoubleShift() {
    if !word.isEmpty, let cur = currentLang() {
        lastWord = (word, "", cur, prev.lang == cur ? prev.words : []); word = []; prev.words = []; lastFix = nil
    }
    if let f = lastFix {
        lastFix = nil
        erase(f.text.count + f.tail.count)
        select(lang: f.lang)
        typeText(swapLayout(f.text, toRu: f.lang == "ru") + f.tail)
    } else if let w = lastWord {
        lastWord = nil
        let ru = w.lang == "ru", b = wrongBefore(w.before, currentRu: ru), fixed = b.text + text(w.keys, ru: !ru)
        erase(b.erase + w.keys.count + w.tail.count)
        select(lang: ru ? "en" : "ru")
        typeText(fixed + w.tail)
        lastFix = (fixed, w.tail, w.lang)  // a second double Shift flips it back
    } else {
        convertSelection()
    }
}

func onFlagsChanged(_ event: CGEvent) {
    let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
    guard code == 56 || code == 60 else { shiftClean = false; return }  // left or right Shift
    if flags.contains(.maskShift) {
        shiftClean = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        shiftDown = Date()
    } else if shiftClean {
        shiftClean = false
        guard Date().timeIntervalSince(shiftDown) < 0.3 else { lastShiftTap = .distantPast; return }  // a held Shift isn't a tap
        if Date().timeIntervalSince(lastShiftTap) < 0.4 { lastShiftTap = .distantPast; onDoubleShift() }
        else { lastShiftTap = Date() }
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return pass
    }
    if event.getIntegerValueField(.eventSourceUserData) == magic { return pass }
    if type == .flagsChanged { onFlagsChanged(event) }
    guard type == .keyDown else {
        // A click moves the caret, so the buffers no longer match the screen.
        // Shift+click selects text, so that Shift press isn't a tap either.
        if type == .leftMouseDown { word = []; prev.words = []; lastFix = nil; lastWord = nil; shiftClean = false }
        return pass
    }
    shiftClean = false; lastShiftTap = .distantPast
    let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
    let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    if plain, keys[code] != nil {
        word.append(Key(code: code, shift: flags.contains(.maskShift) != flags.contains(.maskAlphaShift)))
        lastFix = nil; lastWord = nil
        return pass
    }
    if code == backspace, flags.intersection([.maskCommand, .maskAlternate]).isEmpty {
        if word.isEmpty { prev.words = [] } else { word.removeLast() }
        lastFix = nil; lastWord = nil
        return pass
    }
    defer { word = [] }
    let current = currentLang()
    if prev.lang != current { prev = (current, []) }
    // Space, Return, Tab or any printed sign like "?" ends the word.
    let tail = code == returnKey ? "\n" : code == tabKey ? "\t" : printable(event)
    guard plain, let tail, let current, current == "ru" || current == "en" else {
        prev.words = []; lastFix = nil; lastWord = nil
        return pass
    }
    if word.isEmpty {  // more text after the word, like the space in "ghbdtn? "
        lastFix?.tail += tail
        lastWord?.tail += tail
        prev.words = []  // the next word is no longer one space away from these
        return pass
    }
    guard let fix = fixPhrase(prev.words, word, currentRu: current == "ru") else {
        lastWord = (word, tail, current, prev.words); lastFix = nil
        prev.words = tail == " " ? Array((prev.words + [word]).suffix(5)) : []
        return pass
    }
    prev.words = []; lastWord = nil
    // Swallow the ending key and retype it after the fix so the order on screen stays right.
    erase(fix.erase)
    select(lang: current == "ru" ? "en" : "ru")
    typeText(fix.text + tail)
    lastFix = (fix.text, tail, current)
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
    assert(fixPhrase([], typed("ghbdtn,"), currentRu: false)! == (7, "привет,"))  // comma kept as punctuation
    assert(fixPhrase([], typed("k.,k."), currentRu: false)! == (5, "люблю"))  // here "," and "." are letters
    assert(wrongBefore([typed("hello"), typed("pf"), typed("b")], currentRu: false) == (5, "за и "))  // double Shift on "b pf"
    assert(wrongBefore([typed("hello")], currentRu: false) == (0, ""))
    assert(swapLayout("ghbdtn", toRu: true) == "привет")
    assert(swapLayout("Руддщб", toRu: false) == "Hello,")
    assert(swapLayout("и привет", toRu: false) == "b ghbdtn")  // what double Shift retypes on undo
    print("selftest ok")
    exit(0)
}

final class Actions: NSObject {
    @objc func about() {
        let repo = "https://github.com/puchkoff/flipkey"
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's panel opens behind other windows otherwise
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Fixes words typed in the wrong keyboard layout (Russian ⇄ English).\n\(repo)",
            attributes: [.paragraphStyle: center, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        credits.addAttribute(.link, value: URL(string: repo)!, range: NSRange(location: credits.length - repo.utf16.count, length: repo.utf16.count))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])  // name, version and icon come from the .app bundle
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
let actions = Actions()
// New items go leftmost, where a full menu bar hides them behind the notch; start near the clock instead.
UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Flipkey": 250])
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.autosaveName = "Flipkey"  // keeps the spot after the user Cmd-drags it
let icon = Bundle.main.image(forResource: "MenuBarIcon")  // nil when run as a bare binary, not the .app
icon?.size = NSSize(width: 30, height: 18)
icon?.isTemplate = true  // macOS tints it for light and dark menu bars
item.button?.image = icon ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Flipkey")
item.menu = NSMenu()
item.menu?.addItem(withTitle: "About Flipkey", action: #selector(Actions.about), keyEquivalent: "").target = actions
item.menu?.addItem(.separator())
item.menu?.addItem(withTitle: "Quit Flipkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

// Accessibility access is needed for the key tap; wait for it without blocking, so the icon shows meanwhile.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(prompt)
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
    guard AXIsProcessTrusted() else { return }
    timer.invalidate()
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
    guard let tap else { print("Could not create the event tap."); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}
app.run()
