# Speech mode shortcut

Tycho uses `Cmd+Shift+.` on macOS and `Ctrl+Shift+.` on Windows and Linux to focus the eligible visible conversation composer and start Speech mode. It deliberately avoids bare character shortcuts, `accesskey`, and well-known browser, operating-system, and editor combinations such as `Cmd/Ctrl+K`, `Cmd/Ctrl+Shift+S`, `Cmd/Ctrl+Shift+M`, and `F` keys. We compared the shortcut with the official Chrome and Firefox desktop shortcut lists plus Apple and Microsoft system lists: those lists reserve the familiar conflicting combinations but do not assign the selected combination. This cannot reserve the chord against every application or extension, so Tycho also confines it to an eligible composer and leaves all other contexts alone.

The shortcut is document-level only when one eligible composer can be selected: an already focused composer wins; otherwise Tycho uses the composer for the active agent route, and otherwise the sole visible composer. It does nothing for hidden, inert, disabled, running-agent, or inquiry composers; while a non-composer text input or contenteditable element is focused; while a non-composer dialog is open; during IME composition; on a key repeat; or when speech recognition is unsupported. The Speech button displays the shortcut in its accessible name and title, and has `aria-keyshortcuts` so assistive technology can announce it.

The choice follows W3C guidance: WCAG 2.1 SC 2.1.4 requires a modifier or another safeguard for a global character shortcut; the ARIA Authoring Practices say shortcuts should augment ordinary keyboard access, preserve predictable focus, and be shown on the target control; and ARIA 1.3 says authors should not inhibit operating-system, browser, or assistive-technology functionality. The implementation uses `KeyboardEvent.code === "Period"` with the platform primary modifier and ignores `repeat` and `isComposing`, as defined by the UI Events keyboard model.

Primary sources:

- [WCAG 2.1, Success Criterion 2.1.4](https://www.w3.org/TR/WCAG21/#character-key-shortcuts)
- [WAI-ARIA Authoring Practices: Keyboard Shortcuts](https://www.w3.org/WAI/ARIA/apg/practices/keyboard-interface/#keyboard-shortcuts)
- [WAI-ARIA 1.3: aria-keyshortcuts](https://www.w3.org/TR/wai-aria-1.3/#aria-keyshortcuts)
- [UI Events: KeyboardEvent](https://w3c.github.io/uievents/#interface-keyboardevent)
- [Chrome keyboard shortcuts](https://support.google.com/chrome/answer/157179)
- [Firefox keyboard shortcuts](https://support.mozilla.org/kb/keyboard-shortcuts-perform-firefox-tasks-quickly)
- [Apple macOS keyboard shortcuts](https://support.apple.com/en-us/102650)
- [Windows keyboard shortcuts](https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec)
