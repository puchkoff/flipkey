<p align="center"><img src="logo.svg" width="128" alt="flipkey logo"></p>

# flipkey

flipkey fixes words you typed in the wrong keyboard layout on macOS, the way Punto Switcher does.
Type `ghbdtn`, press Space, and it becomes `привет`. It works in both directions, Russian and English.
While it runs, an A⇄Я icon sits in the menu bar; click it for About or Quit.

When you press Space, Enter or Tab, flipkey looks at the last word in both layouts.
If the word looks wrong in the current layout but is a real word in the other one, flipkey retypes it and switches the layout.
Short words typed just before it in the same wrong layout get fixed too, so `b lfdfq` becomes `и давай`.

A word "looks wrong" when the macOS spell checker rejects it or when it has no vowels.
The vowel rule matters because the spell checker slowly learns words you type often, including mistyped ones like `ghbdtn`.

## Install

Download `flipkey-<version>.zip` from Releases, unzip it, and move `flipkey.app` to Applications.
The app is not notarized yet, so open it the first time with right-click > Open.
Then allow it in System Settings > Privacy & Security > Accessibility. It starts working as soon as you allow it.

## Build

```bash
./build.sh 0.1    # runs the self-test, then builds build/flipkey.app and build/flipkey-0.1.zip
```

The app runs on macOS 13 or later, on both Apple Silicon and Intel.
Each build has a new ad-hoc signature, so macOS asks for Accessibility access again after an update.

## Limits

- It supports only the ABC/US and Russian (ЙЦУКЕН) layouts.
- It has no hotkey to undo or convert a word by hand.
- It ignores `ё` and Russian punctuation keys.
- It leaves alone words the spell checker doesn't know, such as names and slang.
- A short word on its own, like `b` for `и`, is too ambiguous to fix; it is fixed only together with the next word.
