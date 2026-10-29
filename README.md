# CmdQGuard

A tiny macOS menu-bar app that makes **⌘Q** hold-to-quit. For protected apps,
pressing ⌘Q shows a warning HUD and the app only quits after you keep holding
for **0.6 seconds** (adjustable). Release early and nothing happens.

Protection is opt-in: **Safari is enabled initially**, and you can add other
apps (for example, Visual Studio Code) from the Settings window. Every other
app quits immediately with a normal ⌘Q.

> **Note:** ⌘Q is the normal **Quit** shortcut, not Force Quit (that is
> **⌥⌘Esc**). CmdQGuard protects against accidentally quitting an app with
> unsaved changes.

## Build and run

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
open build/CmdQGuard.app
```

For a stable permission grant, move `CmdQGuard.app` somewhere permanent — for
example `/Applications` — before launching it for the first time. Rebuilding
the app changes its ad-hoc code signature, so macOS may ask for permissions
again after a rebuild.

The app has no Dock icon. Look for the **⌘ icon in the menu bar**.

## Grant permissions

Intercepting keys on macOS needs two separate Privacy & Security grants:

1. **Accessibility** — allows CmdQGuard to swallow ⌘Q and send the real quit
   shortcut after the hold.
2. **Input Monitoring** — allows CmdQGuard to see the key events at all.

On first launch the app asks for Accessibility first. Enable **CmdQGuard** in:

- System Settings → Privacy & Security → **Accessibility**
- System Settings → Privacy & Security → **Input Monitoring**

If CmdQGuard is not listed in a pane, click the **+** button and choose the app.
After Accessibility is enabled, the app asks for Input Monitoring. If macOS
does not notice a grant immediately, quit CmdQGuard from its menu and reopen it.
The menu bar icon shows a warning triangle until both permissions are working;
the menu also has direct links to each settings pane.

## Settings

Open **Settings…** from the menu-bar ⌘ icon (or press ⌘, while the app is
active).

- **Enable hold-to-quit** — master on/off switch.
- **Hold time** — how long ⌘Q must be held, from 0.3 to 3.0 seconds. The default
  is **0.6 s**.
- **Launch CmdQGuard at login** — enabled by default.
- **Applications** — protection is opt-in. Only **Safari** is enabled
  initially. Turn on any other app (for example **Visual Studio Code**) to
  protect it; turn it off to let a single ⌘Q quit it immediately.
  - Search to find an app quickly.
  - **Add Protected App…** adds and enables an app from a non-standard folder.
  - **Refresh** rescans installed and running applications.

The app scans `/Applications`, `/System/Applications`, and `~/Applications`,
plus currently running apps. The protected-app list is saved automatically by
bundle identifier, so it survives app updates.

## Launch at login

The app registers itself as a macOS login item using `SMAppService`. This is on
by default, so after the first launch CmdQGuard appears in:

**System Settings → General → Login Items**

If macOS asks for approval, the Settings window shows an **Open Login Items**
button. Turning **Launch CmdQGuard at login** off removes the login item.

If you move the app to a new location, toggle the login option off and back on
once so the login item points at the new copy.

## Use

- **Hold ⌘Q in a protected app** → the app receives a normal ⌘Q after the
  configured hold time (0.6 s by default) and quits.
- **Unprotected apps** → a single ⌘Q quits immediately, with no HUD.
- **Release early** → the HUD fades away and nothing quits.
- **Menu bar ⌘ icon**:
  - *Settings…* — general options and per-app protection.
  - *Warn Before Quitting* — pause/resume protection.
  - *Launch at Login* — quick login-item toggle.
  - *Show Preview* — preview the HUD without holding keys.
  - *Accessibility Settings…* / *Input Monitoring Settings…*.
  - *Quit CmdQGuard*.

The HUD is non-activating, so it appears over the current app (including
full-screen apps) without stealing focus.

## Hold time

Use the **Hold time** slider in Settings. It is saved automatically, so no
rebuild or permission re-grant is needed. Default: **0.6 seconds**; range:
0.3–3.0 seconds.

## Preview without granting permissions

```sh
open -W build/CmdQGuard.app --args --demo
```

Shows the hold-to-quit HUD for a few seconds and exits without quitting
anything.

```sh
open -W build/CmdQGuard.app --args --settings-demo
```

Shows the Settings window for a few seconds and exits.

## Limitations

- **Secure Input** blocks event taps. While a password field (or a terminal with
  "Secure Keyboard Entry") is focused, ⌘Q may pass through unguarded.
- This does not prevent **Force Quit** (⌥⌘Esc), `kill`, crashes, or shutdown.
- Only the plain ⌘Q shortcut is guarded. App-specific quit buttons and
  ⌘⇧Q-style shortcuts are not intercepted.
- The app is **ad-hoc signed**. Rebuilding changes its code identity, so macOS
  may require you to remove and re-add the Accessibility/Input Monitoring
  permissions after a rebuild.
- CmdQGuard must be running. Launch at login keeps it active.

## How it works

`main.swift` creates a `CGEventTap` at the session level. For protected apps it
swallows the ⌘Q key-down (and key repeats), and shows a borderless `NSPanel`
HUD with a timer; unprotected apps receive ⌘Q normally. It cancels if Q or Command is
released. When the bar fills, it posts a real ⌘Q key press so the frontmost app
quits through its normal Quit path — the guard never force-kills anything.

`SettingsView.swift` contains the SwiftUI Settings window, per-app rules, and
the `SMAppService` login-item handling.

## License

MIT — see [LICENSE](LICENSE).
