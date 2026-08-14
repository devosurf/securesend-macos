import AppKit
import Carbon.HIToolbox

// A global hotkey that costs no permission.
//
// `RegisterEventHotKey` asks the window server to deliver one key combination to
// this process. It cannot read other keystrokes, cannot see what is on screen and
// cannot type anywhere, which is exactly why it needs no Accessibility grant. The
// alternative, a CGEventTap, can do all three and would put this app in the same
// permission list as a keylogger, on the strength of one shortcut.
//
// That is also why the hotkey does not replace a selection: replacement means
// faking command-C and command-V, and only a tap can do that. See main.swift.

@MainActor
final class GlobalHotkey {
  /// Control-shift-V. It pairs with control-shift-C for the other direction, and
  /// nothing in the system claims it.
  ///
  /// Fixed for now. The remappable recorder row belongs with the rest of the
  /// settings work, not in front of it.
  static let defaultKey = UInt32(kVK_ANSI_V)
  static let defaultModifiers = UInt32(controlKey | shiftKey)

  private static var pressed: (@MainActor () -> Void)?

  private var hotkey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// Registers the combination, or answers false and leaves the app working.
  ///
  /// A refusal here means something else already owns the combination. It is not
  /// worth an alert on launch: every other way in still works, and a modal on
  /// login is a worse first impression than a shortcut that does nothing.
  @discardableResult
  func install(action: @escaping @MainActor () -> Void) -> Bool {
    Self.pressed = action

    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
    )
    guard
      InstallEventHandler(GetApplicationEventTarget(), hotkeyFired, 1, &spec, nil, &handler)
        == noErr
    else {
      return false
    }

    let id = EventHotKeyID(signature: OSType(0x5353_4E44), id: 1)  // 'SSND'
    return RegisterEventHotKey(
      Self.defaultKey,
      Self.defaultModifiers,
      id,
      GetApplicationEventTarget(),
      0,
      &hotkey
    ) == noErr
  }

  /// How the combination reads in a menu, so the menu and the hotkey cannot drift.
  static var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
    ("v", [.control, .shift])
  }

  fileprivate static func fire() {
    pressed?()
  }
}

/// Carbon hands the press to a C function, so the way back into Swift is a static.
/// There is exactly one hotkey, which is what makes that honest rather than a
/// shortcut around some state that should have been passed in.
private func hotkeyFired(
  _ next: EventHandlerCallRef?,
  _ event: EventRef?,
  _ context: UnsafeMutableRawPointer?
) -> OSStatus {
  DispatchQueue.main.async {
    MainActor.assumeIsolated { GlobalHotkey.fire() }
  }
  return noErr
}
