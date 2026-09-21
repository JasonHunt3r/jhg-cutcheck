# Floating panels on macOS — what worked

Notes from building CutSim's window system: a main document window plus
floating utility panels that snap to each other, remember where they were,
and behave properly on app switch.

Written to be handed to another Claude on another project. Every technique
here is in `sim/Sources/CutSimApp/` and was arrived at by hitting the
problem, not from a tutorial.

**Scope:** SwiftUI app, AppKit underneath, macOS 14+, Swift 6 strict
concurrency. No docking tree, no tear-off, no tab groups — those are weeks
of work and permanent maintenance against undocumented AppKit behaviour.

---

## 1. A SwiftPM executable is not an app

A bare `swift build` binary has no `Info.plist`. macOS then gives it no Dock
icon, no proper menu bar, and **no ⌘Q**. It opens a window and behaves like a
command-line tool that happens to draw.

Wrap it in a bundle. A shell script is enough — no Xcode project needed:

```
build/YourApp.app/
  Contents/
    Info.plist          CFBundleName, CFBundleIdentifier, CFBundleExecutable,
                        LSMinimumSystemVersion, NSHighResolutionCapable
    MacOS/YourApp       the SwiftPM binary, copied
    Resources/
```

Then `codesign --force --sign -` it so Gatekeeper is quiet locally. See
`sim/make-app.sh`. Once bundled, SwiftUI gives you the whole standard menu
bar free: About, Hide, Quit ⌘Q, Edit, Window, Help.

## 2. Panels are `NSPanel` with `.utilityWindow`

That style mask is the thin title bar. It is a real system style — do not
draw your own chrome to imitate it.

```swift
let panel = PanelWindow(
    contentRect: NSRect(origin: .zero, size: defaultSize),
    styleMask: [.titled, .closable, .resizable, .utilityWindow],
    backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.level = .floating          // above the document window, always
panel.hidesOnDeactivate = true   // standard palette behaviour
panel.isReleasedWhenClosed = false   // or it dies on first close
panel.contentView = NSHostingView(rootView: YourSwiftUIView())
```

`isReleasedWhenClosed = false` matters: without it the panel is deallocated
when closed and reopening crashes or silently fails.

Override `canBecomeKey` to return `true`, or the panel cannot take keyboard
focus.

## 3. Snapping: override the frame setters, do not observe moves

The instinct is to watch `windowDidMove` and correct afterwards. That fights
the drag and visibly stutters, because the frame has already been drawn
where the user put it.

AppKit drives a drag through the frame setters, so intercept there and the
correction happens before anything is drawn:

```swift
final class PanelWindow: NSPanel {
    var neighbours: () -> [NSRect] = { [] }
    private var adjusting = false

    // A move: only the origin changes.
    override func setFrameOrigin(_ point: NSPoint) {
        guard !adjusting else { super.setFrameOrigin(point); return }
        adjusting = true; defer { adjusting = false }
        super.setFrameOrigin(snapped(NSRect(origin: point, size: frame.size)).origin)
    }

    // A resize: edges move independently. Only snap during a live resize,
    // or programmatic frame changes (autosave restore, presets) get mangled.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !adjusting, inLiveResize else {
            super.setFrame(frameRect, display: flag); return
        }
        adjusting = true; defer { adjusting = false }
        super.setFrame(snapped(frameRect), display: flag)
    }
}
```

The `adjusting` re-entrancy guard is not optional — `super.setFrame` can
re-enter and you get an infinite loop.

**Two kinds of snap, and you need both:**

```swift
// Butt against the neighbour
considerX(other.maxX - rect.minX)
considerX(other.minX - rect.maxX)
// Line up with it — this is what makes stacks look deliberate
considerX(other.minX - rect.minX)
considerX(other.maxX - rect.maxX)
```

Alignment snapping is the one people forget, and it is the one that makes a
column of panels read as a column rather than a pile. Include the screen's
`visibleFrame` in the candidates.

Pick the smallest delta within ~10pt, per axis, independently.

## 4. Frame persistence is free

```swift
panel.setFrameAutosaveName("panel.moves")
```

macOS stores and restores the frame itself. Do not write your own. The only
thing left to persist is *which* panels were open — a `[String]` in
`UserDefaults`.

Check `panel.frame.origin == .zero` after setting the autosave name to detect
first run and place a sensible default.

## 5. Activation does not raise the document window

Symptom: ⌘-Tab back to the app, the floating panels come forward, the main
window stays behind whatever was in front.

Cause: panels are at `.floating` level so the window server raises them above
everything automatically. The main window is an ordinary window, and
activating an app does not reorder windows that are already visible.

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ n: Notification) { raise() }
    func applicationShouldHandleReopen(_ s: NSApplication,
                                       hasVisibleWindows f: Bool) -> Bool {
        raise(); return true
    }
    private func raise() {
        for w in NSApp.windows
        where !(w is PanelWindow) && w.isVisible && !w.isMiniaturized {
            w.orderFront(nil)     // orderFront, NOT makeKeyAndOrderFront
        }
    }
}
```

`orderFront` rather than `makeKeyAndOrderFront`: a panel that had focus keeps
it. The panels stay on top regardless, by level.

Wire it with `@NSApplicationDelegateAdaptor(AppDelegate.self)`. Mark the
class `@MainActor` or Swift 6 rejects the `NSWindow` calls as non-Sendable.

## 6. `acceptsFirstMouse` for anything you drag

macOS swallows the first click into an inactive window — it raises the window
and stops. So with a panel focused, a click-drag on the main view only
activated the window and the drag did nothing. Two gestures for one action.

```swift
override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
```

**Apply this selectively.** The default exists to stop a stray click
*changing* something in a background window. It is right for a camera control
(harmless, instantly reversible) and wrong for a list whose rows mutate
state — there, swallowing the click is correct.

## 7. Window titles: reach the `NSWindow`

`navigationTitle` and `navigationDocument` fight. `navigationDocument(url)`
gives you the proxy icon and the ⌘-click path menu, but insists the title is
the file name. If you want a custom title *and* the proxy icon, set them
yourself:

```swift
struct WindowChrome: NSViewRepresentable {
    var title: String, subtitle: String = "", url: URL? = nil
    var panelsOnly = false

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let (t, s, u, p) = (title, subtitle, url, panelsOnly)
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            if p && !(w is PanelWindow) { return }   // do not retitle the doc window
            if w.title != t { w.title = t }
            if w.subtitle != s { w.subtitle = s }
            if !p, w.representedURL != u { w.representedURL = u }
        }
    }
}
extension View {
    func windowChrome(title: String, ...) -> some View {
        background(WindowChrome(...).frame(width: 0, height: 0))
    }
}
```

The `async` hop is needed: `view.window` is nil during the first
`updateNSView`. The `!=` guards stop a redraw loop. The `panelsOnly` flag
stops a view that could be hosted anywhere from retitling the wrong window.

**On title content:** Apple's rule is that the title is the document and the
app name lives in the menu bar. That rule assumes your app is frontmost —
when it is not, the menu bar belongs to someone else and a bare filename does
not say whose window this is. `"AppName: file.ext"` is a defensible override,
and users ask for it.

## 8. Menu placement

- **Window menu** for show/hide of panels. That is where Mac users look.
  `CommandGroup(after: .windowArrangement)`.
- **View menu** for what the content looks like, plus layout presets.
- Label the toggles `"Show X"` / `"Hide X"` computed from live state rather
  than using a `Toggle`, so the wording matches what the click will do.

**Shortcut collisions to avoid:**

| Avoid | Because |
|---|---|
| ⌥⌘M | Minimize All, system-wide |
| ⌘1–⌘9 | many apps use these for zoom levels |
| ⌘0 | zoom to fit, conventionally |

Safe conventions: **⌥⌘I** for an inspector (iWork precedent), **⌥⌘1/2/3**
for numbered panels (Xcode precedent).

## 9. Layout stability inside panels

A row that exists only under a condition will insert and remove itself and
shove everything below it around. In a panel showing live state this is
constant and maddening.

Keep the row permanent with a fixed height; change its **text and colour**,
never its existence:

```swift
Label { Text(active ? "zoom detail 0.01mm" : "zoom detail — base grid")
            .lineLimit(1) }
      icon: { Image(systemName: "sparkle.magnifyingglass") }
    .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
    .frame(height: 14, alignment: .leading)
```

`AnyShapeStyle` is needed because the ternary branches must have one type.

## 10. Rows should look like controls

A stack of `Text` does not read as clickable. Three things fix it, cheaply:

- a `Divider()` beneath each row
- a hover highlight — `@State private var hovering` plus `.onHover`
- a secondary value on the right (an index, a count) so the row has structure

Wrap in `Button` with `.buttonStyle(.plain)` and `.contentShape(Rectangle())`
so the whole row is the hit target, not just the text.

## 11. Swift 6 concurrency notes

- Top-level code in `main.swift` is `@MainActor`-isolated. Helper functions
  that touch its variables must be too — or move everything into a `func run()`
  and call it, which is simpler.
- `NSWindow`, `NSApp` and friends are `@MainActor`. Mark delegates
  `@MainActor`.
- Only `Sendable` values may cross an actor boundary. A class holding a
  `[Float]` is not Sendable; the `[Float]` is. Return the array from the
  detached task and rebuild the object on the other side:

```swift
let heights = await Task.detached { … ; return field.h }.value
let rebuilt = HeightField(…); rebuilt.replace(heights: heights)
```

- `@Observable` needs macOS 14. `@Bindable var x: YourModel` gives `$x.field`
  bindings into it from a view.

## 12. Checklist

- [ ] `.app` bundle with an `Info.plist`, else no ⌘Q
- [ ] `isReleasedWhenClosed = false` on every panel
- [ ] `canBecomeKey` overridden to `true`
- [ ] re-entrancy guard in the frame setters
- [ ] snap to *aligned* edges, not only abutting ones
- [ ] `setFrameAutosaveName` before placing defaults
- [ ] raise document windows on `applicationDidBecomeActive`
- [ ] `acceptsFirstMouse` on drag surfaces only
- [ ] no conditionally-inserted rows in live panels
- [ ] shortcuts checked against ⌥⌘M and the ⌘-digit range
