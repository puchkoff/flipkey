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

struct Key { let code: Int64; let shift: Bool; var ru = false }  // ru: the layout this key was typed in
var word: [Key] = []
var prev: (lang: String?, words: [[Key]]) = (nil, [])  // words just before `word`, same layout, not converted
var tap: CFMachPort?
// Text typed after the word ("?", " ") is kept in `tail` so double Shift can erase and retype it.
var lastFix: (text: String, tail: String, lang: String)?  // what double Shift undoes
var lastWord: (keys: [Key], tail: String, lang: String, before: [[Key]])?  // last word left as typed; double Shift converts it
var shiftClean = false, shiftDown = Date.distantPast, lastShiftTap = Date.distantPast  // a "tap" is a quick Shift press with no other key in between
var sources: [String: TISInputSource] = [:]  // the layout last used for each language, so a fix switches back to it
// Words converted by hand with double Shift, keyed "lang:typed text", with how many times.
var learned = UserDefaults.standard.dictionary(forKey: "learned") as? [String: Int] ?? [:]
let learnAfter = 1  // converted by hand this many times -> converted automatically

// Character maps for retyping text in the other layout, e.g. "ghbdtn" <-> "привет".
let enToRu = Dictionary(uniqueKeysWithValues: keys.values.flatMap {
    [(Character($0.0), Character($0.2)), (Character($0.1), Character($0.2.uppercased()))]
})
let ruToEn = Dictionary(uniqueKeysWithValues: enToRu.map { ($1, $0) })

// Real key codes for retyped text, since some apps (remote desktops, VMs) read the code and ignore the string.
let usExtra: [Int64: (String, String)] = [
    0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"), 0x17: ("5", "%"), 0x16: ("6", "^"),
    0x1A: ("7", "&"), 0x1C: ("8", "*"), 0x19: ("9", "("), 0x1D: ("0", ")"), 0x1B: ("-", "_"), 0x18: ("=", "+"),
    0x2C: ("/", "?"), 0x2A: ("\\", "|"), 0x32: ("`", "~"), 0x31: (" ", " "),
]
let keyFor: [Character: (code: Int64, shift: Bool)] = {
    var m: [Character: (code: Int64, shift: Bool)] = [:]
    for (c, t) in usExtra { m[Character(t.1)] = (c, true); m[Character(t.0)] = (c, false) }  // unshifted space wins
    for (c, t) in keys {
        for (s, shift) in [(t.0, false), (t.1, true), (t.2, false), (t.2.uppercased(), true)] { m[Character(s)] = (c, shift) }
    }
    return m
}()
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

// Slang and names ("pfrjvvbxty" = "закоммичен") are in no dictionary, so converted() misses them.
// Convert anyway when the typed text is clear nonsense: no vowels, a sign inside the word, or no spelling guesses.
func gibberish(_ s: String, _ lang: String) -> Bool {
    guard s.count >= 4, !isWord(s, lang) else { return false }
    if !s.contains(where: vowels[lang]!.contains) { return true }
    if s.dropFirst().dropLast().contains(where: { !$0.isLetter }) { return true }
    let g = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: s.utf16.count), in: s,
                                          language: lang, inSpellDocumentWithTag: 0) ?? []
    return g.isEmpty
}

func guessFix(_ w: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    let cur = text(w, ru: ru), other = text(w, ru: !ru), otherLang = ru ? "en" : "ru"
    guard other.allSatisfy(\.isLetter), other.contains(where: vowels[otherLang]!.contains),
          gibberish(cur, ru ? "ru" : "en") else { return nil }
    return (w.count, other)
}

// Enter often sends a message at once, so only sure fixes run there: learned words, nonsense, no vowels.
func enterFix(_ w: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    if let f = learnedFix(w, currentRu: ru) ?? guessFix(w, currentRu: ru) { return f }
    let cur = text(w, ru: ru)
    guard cur.count >= 3, !cur.contains(where: vowels[ru ? "ru" : "en"]!.contains),
          let f = converted(w, currentRu: ru) else { return nil }
    return (w.count, f)
}

// The words right before a word, each followed by one space, that were typed in the same wrong layout,
// like "b" in "b ghbdtn". Returns how many characters they take and their fixed text, spaces included.
func wrongBefore(_ prev: [[Key]], currentRu ru: Bool, minLength: Int = 1) -> (erase: Int, text: String) {
    var text = "", erase = 0
    for p in prev.reversed() {
        guard p.count >= minLength, let f = converted(p, currentRu: ru) else { break }
        text = f + " " + text
        erase += p.count + 1
    }
    return (erase, text)
}

// Fixes the word plus the words right before it that were typed in the same wrong layout,
// so "bf ghbdtn" becomes "иа привет". Single letters are never fixed automatically: "B" is often meant.
func fixPhrase(_ prev: [[Key]], _ word: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    var core = word, tail = ""
    while true {
        if core.count >= 2, let fix = converted(core, currentRu: ru) {
            let b = wrongBefore(prev, currentRu: ru, minLength: 2)
            return (b.erase + word.count, b.text + fix + tail)
        }
        // In "ghbdtn," the comma key is the Russian "б" but was meant as punctuation; retry without it.
        guard !ru, let k = core.last, !Character(keys[k.code]!.0).isLetter else { return nil }
        tail = text([k], ru: false) + tail
        core.removeLast()
    }
}

// A word whose keys were typed in both layouts, e.g. when the layout switched mid-word, shows half in each script.
// Retype it all in one layout: the one where it is a real word, else the layout it started in.
func mixedFix(_ w: [Key], currentRu ru: Bool) -> (erase: Int, text: String, ru: Bool)? {
    guard let first = w.first, w.contains(where: { $0.ru != first.ru }) else { return nil }
    var toRu = first.ru
    if isWord(text(w, ru: ru), ru ? "ru" : "en") { toRu = ru } else if isWord(text(w, ru: !ru), ru ? "en" : "ru") { toRu = !ru }
    return (w.count, text(w, ru: toRu), toRu)
}

func learnKey(_ w: [Key], _ lang: String) -> String { lang + ":" + text(w, ru: lang == "ru").lowercased() }
func saveLearned() { UserDefaults.standard.set(learned, forKey: "learned") }
func learn(_ w: [Key], _ lang: String) { learn(key: learnKey(w, lang)) }
func learn(key: String) { learned[key, default: 0] += 1; saveLearned() }
// A selection is learned only when it is one word made of layout keys, so it matches what typing produces.
func learn(selection sel: String, fromRu ru: Bool) {
    guard !sel.isEmpty, sel.allSatisfy({ (ru ? ruToEn : enToRu)[$0] != nil }) else { return }
    learn(key: (ru ? "ru:" : "en:") + sel.lowercased())
}
func learnedFix(_ w: [Key], currentRu ru: Bool) -> (erase: Int, text: String)? {
    w.count >= 2 && (learned[learnKey(w, ru ? "ru" : "en")] ?? 0) >= learnAfter ? (w.count, text(w, ru: !ru)) : nil
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
    // The system applies our own switch a moment late; trust it so the next keys aren't tagged with the old layout.
    if let (w, at) = lastSelect, Date().timeIntervalSince(at) < 0.6 { return w }
    return l
}

var lastSelect: (String, Date)?

func select(lang wanted: String) {
    lastSelect = (wanted, Date())
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
        default:
            let k = keyFor[ch]  // unknown signs keep code 0; apps that read the string still get them right
            post(CGKeyCode(k?.code ?? 0), String(ch), flags: k?.shift == true ? .maskShift : [])
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
        learn(selection: sel, fromRu: !toRu)
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
        learn(w.keys, w.lang)
        let ru = w.lang == "ru", b = wrongBefore(w.before, currentRu: ru), fixed = b.text + text(w.keys, ru: !ru)
        erase(b.erase + w.keys.count + w.tail.count)
        select(lang: ru ? "en" : "ru")
        typeText(fixed + w.tail)
        lastFix = (fixed, w.tail, w.lang)  // a second double Shift flips it back
    } else {
        convertSelection()
    }
}

// Backspace erases the word being typed first, then the text after the last fix or word, then that fix or word.
func onBackspace() {
    if !word.isEmpty { word.removeLast(); return }
    prev.words = []
    if lastFix?.tail.isEmpty == false { lastFix!.tail.removeLast() } else { lastFix = nil }
    if lastWord?.tail.isEmpty == false { lastWord!.tail.removeLast() } else { lastWord = nil }
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
        // lastFix and lastWord stay: if this word is erased again, double Shift still reaches them.
        // No mid-word switch: prefix guesses were wrong too often; the word is fixed when it ends.
        word.append(Key(code: code, shift: flags.contains(.maskShift) != flags.contains(.maskAlphaShift),
                        ru: currentLang() == "ru"))
        return pass
    }
    if code == backspace, flags.intersection([.maskCommand, .maskAlternate]).isEmpty {
        onBackspace()
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
    if code == returnKey, enterFix(word, currentRu: current == "ru") == nil {
        lastWord = (word, tail, current, prev.words); lastFix = nil; prev.words = []
        return pass
    }
    if let m = mixedFix(word, currentRu: current == "ru") {
        prev.words = []; lastWord = nil
        erase(m.erase)
        if m.ru != (current == "ru") { select(lang: m.ru ? "ru" : "en") }
        typeText(m.text + tail)
        lastFix = (m.text, tail, m.ru ? "en" : "ru")  // double Shift flips it to the other layout
        return nil
    }
    let isRu = current == "ru"
    guard let fix = code == returnKey ? enterFix(word, currentRu: isRu)
            : fixPhrase(prev.words, word, currentRu: isRu) ?? learnedFix(word, currentRu: isRu)
            ?? guessFix(word, currentRu: isRu) else {
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
    assert(fixPhrase([typed("b")], typed("ghbdtn"), currentRu: false)! == (6, "привет"))  // "B" may be meant
    assert(fixPhrase([typed("pf")], typed("ghbdtn"), currentRu: false)! == (9, "за привет"))
    assert(fixPhrase([typed("hello"), typed("d")], typed("ljvt"), currentRu: false)! == (4, "доме"))
    assert(fixPhrase([], typed("ghbdtn,"), currentRu: false)! == (7, "привет,"))  // comma kept as punctuation
    assert(fixPhrase([], typed("k.,k."), currentRu: false)! == (5, "люблю"))  // here "," and "." are letters
    assert(wrongBefore([typed("hello"), typed("pf"), typed("b")], currentRu: false) == (5, "за и "))  // double Shift on "b pf"
    assert(wrongBefore([typed("hello")], currentRu: false) == (0, ""))
    assert(swapLayout("ghbdtn", toRu: true) == "привет")
    assert(swapLayout("Руддщб", toRu: false) == "Hello,")
    assert(swapLayout("и привет", toRu: false) == "b ghbdtn")  // what double Shift retypes on undo
    assert(keyFor["П"]! == (0x05, true) && keyFor["?"]! == (0x2C, true) && keyFor[" "]! == (0x31, false))
    // "Vfif " left alone, then "abc" typed and erased: double Shift must still reach "Vfif".
    lastWord = (typed("vfif"), " ", "en", []); word = typed("ab")
    onBackspace(); onBackspace()
    assert(lastWord?.tail == " ")
    onBackspace()  // the space
    assert(lastWord?.tail == "")
    onBackspace()  // into the word itself, so it no longer matches the screen
    assert(lastWord == nil)
    learned = [:]
    assert(learnedFix(typed("nbgf"), currentRu: false) == nil)
    learn(typed("nbgf"), "en")
    assert(learnedFix(typed("nbgf"), currentRu: false)! == (4, "типа"))
    learned = [:]
    learn(selection: "Nbgf", fromRu: false); learn(selection: "nbgf", fromRu: false)
    assert(learnedFix(typed("nbgf"), currentRu: false)! == (4, "типа"))
    learn(selection: "b ghbdtn", fromRu: false)  // several words: not learned
    assert(learned["en:b ghbdtn"] == nil)
    learned = [:]
    let mixed = typed("ghbdtn").enumerated().map { Key(code: $1.code, shift: false, ru: $0 >= 3) }  // "ghbвет"
    assert(mixedFix(mixed, currentRu: true)! == (6, "привет", true))
    assert(mixedFix(typed("hello"), currentRu: false) == nil)
    assert(guessFix(typed("cvthl;ty"), currentRu: false)! == (8, "смерджен"))  // ";" inside the word
    assert(guessFix(typed("hello"), currentRu: false) == nil)
    assert(guessFix(typed("ghbdtn"), currentRu: true) == nil)  // "привет" is a real word
    assert(enterFix(typed("ghbdtn"), currentRu: false)! == (6, "привет"))  // no vowels
    assert(enterFix(typed("hello"), currentRu: false) == nil)
    print("selftest ok")
    exit(0)
}

final class Actions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow?
    let table = NSTableView()
    let clear = NSButton(title: "Clear All", target: nil, action: nil)
    var words: [String] = []
    @objc func showLearned() {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window?.title = "Learned Words"
            window?.isReleasedWhenClosed = false
            for (id, title) in [("typed", "Typed"), ("fixed", "Becomes"), ("remove", "")] {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                col.title = title
                if id == "remove" { col.width = 28; col.minWidth = 28; col.maxWidth = 28 }
                table.addTableColumn(col)
            }
            table.style = .inset
            table.usesAlternatingRowBackgroundColors = true
            table.rowHeight = 26
            table.dataSource = self; table.delegate = self
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
            clear.target = self; clear.action = #selector(clearAll)
            let content = NSStackView(views: [scroll, clear])
            content.orientation = .vertical; content.alignment = .trailing
            content.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 16)
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            window?.contentView = content
            window?.center()
        }
        reloadLearned()
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's window opens behind other windows otherwise
        window?.makeKeyAndOrderFront(nil)
    }
    func reloadLearned() {
        words = learned.filter { $0.value >= learnAfter }.keys.sorted()
        clear.isEnabled = !learned.isEmpty
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { words.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let k = words[row], typed = String(k.dropFirst(3))
        switch column?.identifier.rawValue {
        case "typed":
            let l = NSTextField(labelWithString: typed); l.textColor = .secondaryLabelColor; return l
        case "fixed":
            let l = NSTextField(labelWithString: swapLayout(typed, toRu: k.hasPrefix("en")))
            l.font = .boldSystemFont(ofSize: NSFont.systemFontSize); return l
        default:
            let b = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")!,
                             target: self, action: #selector(forget(_:)))
            b.isBordered = false; b.contentTintColor = .secondaryLabelColor; b.toolTip = "Remove"
            b.identifier = NSUserInterfaceItemIdentifier(k); return b
        }
    }
    @objc func forget(_ sender: NSButton) { learned[sender.identifier!.rawValue] = nil; saveLearned(); reloadLearned() }
    @objc func clearAll() { learned = [:]; saveLearned(); reloadLearned() }

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
item.menu?.addItem(withTitle: "Learned Words…", action: #selector(Actions.showLearned), keyEquivalent: "").target = actions
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
