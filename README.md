<p align="center"><img src="logo.svg" width="128" alt="flipkey logo"></p>

# flipkey

flipkey fixes words you typed in the wrong keyboard layout on macOS, the way Punto Switcher does.
Type `ghbdtn`, press Space, and it becomes `привет`. It works in both directions, Russian and English.

When you press Space, Enter or Tab, flipkey checks the last word with the macOS spell checker.
If the word is not valid in the current layout but is valid in the other one, flipkey retypes it and switches the layout.

## Build and run

```bash
swiftc -O -o flipkey main.swift
./flipkey
```

On the first run, macOS asks for Accessibility access. Allow it for your terminal (or the `flipkey` binary) in System Settings > Privacy & Security > Accessibility, then run it again.

To check the conversion logic without any permissions, run:

```bash
swiftc -Onone -o flipkey main.swift && ./flipkey --selftest
```

## Limits

- It supports only the ABC/US and Russian (ЙЦУКЕН) layouts.
- It has no hotkey to undo or convert a word by hand.
- It ignores `ё` and Russian punctuation keys.
- It leaves alone words the spell checker doesn't know, such as names and slang.
