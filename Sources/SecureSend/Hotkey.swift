import AppKit
import Carbon.HIToolbox

// Global hotkeys that cost no permission.
//
// `RegisterEventHotKey` asks the window server to deliver one key combination to
// this process. It cannot read other keystrokes, cannot see what is on screen and
// cannot type anywhere, which is exactly why it needs no Accessibility grant. The
// alternative, a CGEventTap, can do all three and would put this app in the same
// permission list as a keylogger, on the strength of two shortcuts.
//
// That is also why neither hotkey replaces a selection: replacement means faking
// command-C and command-V, and only a tap can do that. See main.swift.
//
// Measured on macOS 26.5.1, and worth knowing before trusting what `install`
// returns: registering a combination another *process* already holds succeeds.
// Carbon only answers `eventHotKeyExistsErr` for a duplicate inside one process.
// So a clash with somebody else's app is silent here, and the press just goes to
// whoever the window server picked. That is the argument for letting people remap
// a shortcut, not for trying to detect the clash.

/// The two directions, one combination each: control-shift-C makes a link out of
/// the clipboard, control-shift-V opens one that is already on it.
///
/// Fixed for now. The remappable recorder row belongs with the rest of the
/// settings work, not in front of it.
enum Shortcut: UInt32, CaseIterable, Sendable {
  case generate = 1
  case consume = 2

  var keyCode: UInt32 {
    switch self {
    case .generate: return UInt32(kVK_ANSI_C)
    case .consume: return UInt32(kVK_ANSI_V)
    }
  }

  var modifiers: UInt32 { UInt32(controlKey | shiftKey) }

  /// How the combination reads in a menu, so the menu and the hotkey cannot drift.
  var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
    switch self {
    case .generate: return ("c", [.control, .shift])
    case .consume: return ("v", [.control, .shift])
    }
  }

  /// For the boot line. Which shortcut, never what it carried.
  var name: String {
    switch self {
    case .generate: return "control-shift-C"
    case .consume: return "control-shift-V"
    }
  }
}

@MainActor
final class GlobalHotkey {
  private static var pressed: (@MainActor (Shortcut) -> Void)?

  private var registered: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?

  /// Registers every combination and answers with the ones the window server gave
  /// us.
  ///
  /// A refusal is not worth an alert on launch: every other way in still works,
  /// and a modal on login is a worse first impression than a shortcut that does
  /// nothing. The menu is told what was actually taken so it can stop advertising
  /// what was not.
  @discardableResult
  func install(action: @escaping @MainActor (Shortcut) -> Void) -> Set<Shortcut> {
    Self.pressed = action

    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
    )
    guard
      InstallEventHandler(GetApplicationEventTarget(), hotkeyFired, 1, &spec, nil, &handler)
        == noErr
    else {
      return []
    }

    var held: Set<Shortcut> = []
    for shortcut in Shortcut.allCases {
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x5353_4E44), id: shortcut.rawValue)  // 'SSND'
      guard
        RegisterEventHotKey(
          shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref
        ) == noErr,
        let ref
      else {
        continue
      }
      registered.append(ref)
      held.insert(shortcut)
    }
    return held
  }

  fileprivate static func fire(_ raw: UInt32) {
    guard let shortcut = Shortcut(rawValue: raw) else { return }
    pressed?(shortcut)
  }
}

/// Carbon hands the press to a C function, so the way back into Swift is a static.
/// Which combination it was rides in the event rather than in state out here,
/// because the handler is shared by all of them.
private func hotkeyFired(
  _ next: EventHandlerCallRef?,
  _ event: EventRef?,
  _ context: UnsafeMutableRawPointer?
) -> OSStatus {
  var id = EventHotKeyID()
  guard
    GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &id
    ) == noErr
  else {
    return noErr
  }

  let raw = id.id
  DispatchQueue.main.async {
    MainActor.assumeIsolated { GlobalHotkey.fire(raw) }
  }
  return noErr
}
