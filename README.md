# SecureSend for macOS

Select a secret anywhere on your Mac, right-click, and it becomes a one-time
SecureSend link. The link opens once, then it is gone.

The app asks for zero permissions. No Accessibility, no Input Monitoring, no
notifications, nothing. macOS Services are the whole mechanism: the system hands
the app your selection, the app hands back a link, and the host application puts
it where the selection was.

The secret is encrypted on your machine before anything leaves it, with the same
AES-256-GCM envelope the web app uses. The key rides in the link's fragment, the
part after the `#`, which browsers never send to a server. securesend.dev
receives ciphertext it cannot read.

**Anyone holding the whole link can decrypt it. The link is the secret, so treat
it like one.**

## What it does

- **Replace with SecureSend link.** Right-click a selection in any app that
  accepts a replacement, and the selected text is swapped for the link.
- **Copy as SecureSend link.** The same thing, but the link lands on your
  clipboard and the selection is left alone. This is the fallback for anything
  that will not take a replacement, and for text you cannot edit.
- **Generate from clipboard.** From the menu bar item, for when there is no live
  selection.

Links expire in 24 hours, the same default the web app starts from. A right-click
has no screen to choose an expiry on, so the app picks the one you would have.

Neither Service ships with a keyboard shortcut, because every obvious combination
already belongs to something. Assign your own under System Settings > Keyboard >
Keyboard Shortcuts > Services.

Nothing is ever logged except app names and lengths. The log lives at
`~/Library/Logs/securesend.log` and is reachable from the menu. Links and secret
content never touch it, because a link in a log file would undo the whole product.

## Building it

Requires macOS 14 or later and a Swift 6 toolchain. Xcode is not needed; the
Command Line Tools are enough.

```sh
./scripts/build.sh
```

That compiles with SwiftPM, assembles `SecureSend.app` into `~/Applications`,
signs it ad-hoc, and registers the Services with Launch Services. Set `DEST` to
install somewhere else and `SIGN_IDENTITY` to sign with a real certificate.

If a Service does not appear in the right-click menu, it is almost always Launch
Services caching. `./scripts/build.sh` flushes it, and a logout always fixes it.

### Layout

| Path                    | What it is                                            |
| ----------------------- | ----------------------------------------------------- |
| `Sources/SecureSend`    | the menu bar app and the two Service handlers          |
| `Sources/SecureSendKit` | the crypto envelope, the API call, the mark            |
| `Sources/vector`        | prints a sealed envelope, for checking against the web |
| `Sources/preview`       | renders the menu bar mark at candidate sizes           |
| `Resources/Info.plist`  | the Services registration, which is the whole contract |

SwiftPM builds the binaries and `scripts/build.sh` assembles the `.app` around
them, because SwiftPM has no notion of an application bundle and the Services
live entirely in the Info.plist.

The envelope in `Sources/SecureSendKit/Crypto.swift` is a CryptoKit port of the
web app's `packages/crypto`. Every constant is named after its counterpart there,
so drift in either shows up as a failed round trip. `vector seal <note>` prints
what this app would send, for checking that by hand.

## Releasing it

One number lives in three places: the git tag, `CFBundleShortVersionString` and
`CFBundleVersion` in the Info.plist, and the name on the release page. Check for
updates compares the number in your copy against the number on `releases/latest`,
so if those drift apart an installed app is told the wrong thing. One script sets
all of them and the release refuses to build when they disagree.

```sh
./scripts/version.sh 0.2.0
git push --follow-tags
```

That is the whole release. The tag starts
[`.github/workflows/release.yml`](.github/workflows/release.yml) on a macOS
runner, which builds the app, signs it with the Developer ID certificate,
notarizes it with Apple, staples the ticket to both the app and the dmg, and
attaches `SecureSend-0.2.0.dmg` to the GitHub release with its sha256 in the
notes. Nothing between the tag and the download is done by hand.

`./scripts/package.sh` is the same build, runnable here. With
`SIGN_IDENTITY` alone it produces a signed dmg that only opens on this machine,
which is enough to check the packaging. Add the notary variables and it produces
the real thing.

### The secrets a fork needs

Signing and notarizing need an Apple Developer Program membership. Fork this and
you need your own; set these five in the repository's Actions secrets and the
workflow works unchanged.

```sh
./scripts/setup-signing.sh
```

That walks you through getting all five and installs them. It checks the
certificate really is a Developer ID Application one with its private key, by
importing it the same way the runner does, and it asks Apple to accept the
notarization key before it stores anything. The two are gated at different
heights: a Developer ID certificate can only be created by the account's Account
Holder, while the notarization key needs no more than an Admin. The wizard asks
which of those you are, and for whatever you cannot make yourself it writes the
message to send the person who can.

When somebody else holds the account, the signing request is still made here.
They upload it and send back the certificate, which means the private key that
signs the app never leaves this machine, and there is no password for anyone to
transmit. That is a shorter favour to ask than an export, and a safer one to
grant.

| Secret                        | What it is                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| `MACOS_CERTIFICATE`           | your Developer ID Application certificate and key, exported as a `.p12`, then base64 encoded |
| `MACOS_CERTIFICATE_PASSWORD`  | the password you gave that export                                                            |
| `NOTARY_KEY`                  | an App Store Connect API key, the `.p8` file, base64 encoded                                 |
| `NOTARY_KEY_ID`               | that key's Key ID                                                                            |
| `NOTARY_ISSUER_ID`            | the Issuer ID shown above the key list                                                       |

`base64 -i certificate.p12 | pbcopy` gets a file into a secret. The signing
identity itself is not a secret: the workflow reads it back out of the imported
certificate, so renewing the certificate is one secret to replace and nothing
else to keep in step.

An API key rather than an Apple ID and an app-specific password, because the key
is scoped to notarization, can be revoked on its own, and does not put a personal
Apple ID credential into a repository.

## License

AGPL-3.0-or-later, the same as the rest of SecureSend. See [LICENSE](LICENSE).
