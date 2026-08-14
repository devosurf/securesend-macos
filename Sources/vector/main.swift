import Foundation
import SecureSendKit

// Two modes, so the crypto can be checked offline and the wire checked on purpose.
//
//   vector seal <note>          prints the sealed envelope as json, no network
//   vector create <note> [1h]   posts to securesend.dev and prints the link

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "seal"
let note = args.count > 2 ? args[2] : "hunter2"

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

default:
  FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
  exit(2)
}
