# SecureSend for macOS

Select a secret anywhere on your Mac, right-click, and it becomes a one-time
SecureSend link. The link opens once, then it is gone. Press control-shift-V on
somebody else's link and it opens back into a secret, without a browser.

The app asks for no Accessibility, no Input Monitoring and no notifications, and
it never reads your clipboard to find out whether there is a link on it. macOS
Services are the whole mechanism on the way out: the system hands the app your
selection, the app hands back a link, and the host application puts it where the
selection was. Files work the same way, from Finder.

The one thing macOS may ask you is its standard "access files in your Downloads
folder" consent, and only if somebody sends you a secret with files in it, at the
moment those files are saved. Sending a file does not ask, even out of a
protected folder: a file you picked in Finder is handed to the app by the system,
which is consent you already gave by picking it. Measured on 26.5, sending a file
off the Desktop, with no entry for this app in the privacy database before or
after. Nothing else here touches a protected folder.

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
- **Copy files as SecureSend link.** Pick files in Finder, right-click, and they
  go the same way: encrypted here, uploaded as ciphertext, and the link lands on
  your clipboard. Up to 10 files and 10 MB in one link, which is what the server
  stores. Anything past that is refused before a byte is read, so a disk image
  costs you a sentence rather than a minute.
- **Generate from clipboard.** Copy the secret, press control-shift-C, and the
  link replaces it on your clipboard. Also in the menu bar item, for when there
  is no live selection.
- **Open link from clipboard.** The reverse. Copy a SecureSend link somebody sent
  you, press control-shift-V, and the app opens it: the note lands on your
  clipboard, files land in your Downloads folder.

Links expire in 24 hours, the same default the web app starts from. A right-click
has no screen to choose an expiry on, so the app picks the one you would have.

## Shortcuts

Two, both fixed for now: control-shift-C makes a link out of your clipboard, and
control-shift-V opens one that is on it. There is no settings window yet, so
neither can be changed inside the app. If another app already owns one of these
combinations, macOS gives it to whichever asked first and says nothing to either,
so the symptom is a shortcut that quietly does nothing; the menu bar item does
the same job in the meantime.

The three Services ship with no shortcut at all, because every obvious
combination is somebody else's. You can give them one yourself in System Settings
> Keyboard > Keyboard Shortcuts > Services.

## Opening a link

Opening is the one thing this product does that cannot be undone, so the app
takes the long way round.

It never reads your clipboard to find out whether a link is on it. macOS 15.4
added an alert for programmatic pasteboard reads, on by default from macOS 26,
and a secrets app that trips it on every keypress reads as a clipboard snooper.
Instead the app asks the system what patterns it can see, which answers without
handing over the contents and without the alert.

Before anything is destroyed it asks securesend.dev what is at the link. That
call is a plain lookup with no path to a write, so a link that is already spent,
expired or destroyed says so without costing you a press. Only a live link gets
the confirmation panel, and only the panel's own button sends the reveal.

A password-protected link is handed to your browser instead. The app can tell
from the fragment alone, before it asks the server anything, and the web page
already knows how to prompt, how to let a wrong password be tried again, and how
to say what opening costs. Opening that page destroys nothing on its own.

If a link arrives without the part after the `#`, the app says so and stops.
That part is the key, chat clients drop it, and there is nothing to request.

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

| Path                     | What it is                                              |
| ------------------------ | ------------------------------------------------------- |
| `Sources/SecureSend`     | the menu bar app, the Service handlers, the consume flow |
| `Sources/SecureSendKit`  | the crypto envelope, the API calls, the update check, the mark |
| `Sources/vector`         | seals, creates and consumes from the terminal            |
| `Sources/preview`        | renders the menu bar mark at candidate sizes             |
| `Sources/icon`           | draws the app icon, via `scripts/icon.sh`                |
| `Tests/SecureSendKitTests` | the offline checks, including the cross-implementation ones |
| `Resources/Info.plist`   | the Services registration, which is the whole contract   |

SwiftPM builds the binaries and `scripts/build.sh` assembles the `.app` around
them, because SwiftPM has no notion of an application bundle and the Services
live entirely in the Info.plist.

The envelope in `Sources/SecureSendKit` is a CryptoKit port of the web app's
`packages/crypto`. Every constant is named after its counterpart there, so drift
in either shows up as a failed round trip.

```sh
swift test
```

`Tests/SecureSendKitTests/Fixtures/envelopes.json` holds envelopes sealed by
`packages/crypto` itself, covering notes, logins, files, unicode and a
password-protected one. Opening them in Swift is the check that the two
implementations still read each other, and it runs offline.
`scripts/make-fixtures.ts` regenerates the file; its header says how.

For checking the wire on purpose, `vector` does each step by hand:

```sh
vector seal "a note"      # the sealed envelope as json, no network
vector create "a note"    # posts it and prints the link
vector send a.txt b.pdf   # the Finder service without Finder: posts the files
vector status <link>      # what is at a link. Destroys nothing
vector consume <link>     # the receiving side, end to end. Destroys the link
vector updates 0.1.0      # what the releases api names, and how it ranks
```

## Getting it

Every release carries the same dmg under two names. Link to this one and it
always resolves to the newest release, so nothing has to be edited when a
version ships:

```
https://github.com/devosurf/securesend-macos/releases/latest/download/SecureSend.dmg
```

The versioned `SecureSend-X.Y.Z.dmg` beside it is the one to keep if you want to
check a download against the sha256 in the release notes.

## Staying current

**Check for updates** in the menu asks GitHub for the latest release and compares
it against the version this copy was built with. If there is a newer one it
offers the release page, where the notes and the checksum are. Updating is then
the same drag it was the first time, after quitting the running copy.

It asks only when you click it. There is no check on launch and no timer, because
a tool that talks to a server on its own schedule is a different promise from the
one the rest of this app makes, and GitHub sees an address every time it is asked.
Nothing downloads or replaces itself either: this app has no updater, it has a
question it can ask.

## Releasing it

One number lives in three places: the git tag, `CFBundleShortVersionString` and
`CFBundleVersion` in the Info.plist, and the name on the release page. One script
sets all of them and the release refuses to build when they disagree.

Keeping them in step is what Check for updates depends on, since it compares the
number in your copy against the tag on `releases/latest`. If they drift apart an
installed app is told the wrong thing.

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

Apple issues your certificate but not the authority above it, so the wizard
fetches the matching Developer ID intermediate and packs it in beside the
certificate. Without it macOS finds the identity and then calls it invalid,
which reads like a bad certificate and is not one. That is also why building the
`.p12` needs a network connection for a moment.

The request is made with `openssl` rather than through Keychain Access, and the
certificate that comes back is paired with its key the same way. Certificate
Assistant fails on some machines with "The specified item could not be found in
the keychain" and offers nothing to debug; a command that behaves identically
every time is worth more here than a dialog. Everything lives in
`~/.securesend-signing`, and the wizard offers to remove it once the secrets are
installed.

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
