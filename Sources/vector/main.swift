import Foundation
import SecureSendKit

// Modes, so the crypto can be checked offline and the wire checked on purpose.
//
//   vector seal <note>          prints the sealed envelope as json, no network
//   vector create <note> [1h]   posts to securesend.dev and prints the link
//   vector status <link>        asks what is at a link, destroys nothing
//   vector consume <link>       the receiving side, end to end. DESTROYS the link
//
// `consume` is the app's flow without the app: the same status call, the same
// reveal, the same open. It prints what came out, which is why it is a
// development tool and not something to point at a real secret.

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "seal"
let note = args.count > 2 ? args[2] : "hunter2"

/// Reads the argument as one of our links, or stops with the reason.
func linkArgument() -> (id: String, token: SecureSendCrypto.FragmentToken) {
  guard args.count > 2 else {
    FileHandle.standardError.write(Data("\(mode) needs a link\n".utf8))
    exit(2)
  }

  guard case .link(let id, let fragment) = SecureSendLink.read(args[2]) else {
    FileHandle.standardError.write(Data("that is not a complete securesend link\n".utf8))
    exit(2)
  }
  guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(fragment) else {
    FileHandle.standardError.write(Data("the fragment is not a key\n".utf8))
    exit(2)
  }

  return (id, token)
}

switch mode {
case "seal":
  let sealed = try SecureSendCrypto.seal(note: note)
  let out: [String: Any] = [
    "attachments": [],
    "envelope": ["ciphertext": sealed.ciphertext, "iv": sealed.iv],
    "fragmentToken": sealed.fragmentToken,
    "id": sealed.id,
    "note": note,
  ]
  let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))

case "create":
  let expiry = SecureSendAPI.Expiry(rawValue: args.count > 3 ? args[3] : "1h") ?? .oneHour
  print(try SecureSendAPI.createLink(note: note, expiry: expiry))

case "status":
  let found = try await SecureSendAPI.status(id: linkArgument().id)
  print("state:     \(found.state)")
  print("createdAt: \(found.createdAt.map(String.init(describing:)) ?? "?")")
  print("expiresAt: \(found.expiresAt.map(String.init(describing:)) ?? "?")")
  print("usedAt:    \(found.usedAt.map(String.init(describing:)) ?? "-")")
  print("burnedAt:  \(found.burnedAt.map(String.init(describing:)) ?? "-")")

case "consume":
  let (id, token) = linkArgument()

  let before = try await SecureSendAPI.status(id: id)
  print("before:    \(before.state)")
  guard before.state.isOpenable else {
    FileHandle.standardError.write(Data("nothing to take\n".utf8))
    exit(1)
  }

  let opened = try SecureSendCrypto.open(
    stored: try await SecureSendAPI.reveal(id: id), token: token
  )
  print("note:      \(opened.note ?? "-")")
  print("login:     \(opened.credentials.map { "\($0.username) / \($0.password)" } ?? "-")")
  for file in opened.files {
    print("file:      \(file.name) (\(file.size) bytes, \(file.type.isEmpty ? "no type" : file.type))")
  }
  print("clipboard: \(opened.clipboardText.map { "\($0.count)ch" } ?? "nothing")")

  // The same second call the app never makes, to prove the link really is spent.
  print("after:     \(try await SecureSendAPI.status(id: id).state)")

default:
  FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
  exit(2)
}
