# Validation

## Version 1.3.0 preparation (October 31, 2026)

`./test.sh` passes for the free download/decrypt workflow, mocked sign-in and verification-code retries, secret clearing, all three platform routes, cancellation, model validation, automatic setup/resume, and sign-out. No live Apple account was used in these tests. The donation button uses the configured 100xtoday link and stops pulsing with Reduce Motion or an inactive scene. The finished app was opened and visually checked: the yellow coffee button and logo are at the top right, and accessibility reports the correct donation URL. Reduce Motion behavior is implemented but was not toggled in this check.

The source upload archive is generated from an explicit project allowlist and vendor-tracked files, with local integration changes included. It excludes Git histories, account state, Keychain contents, models, captures, downloads, caches, and binaries. A signature scan found no local home-directory paths, private-key blocks, or GitHub token signatures. This is a scoped packaging check, not a guarantee against every possible secret format.

After explicit user approval, the release build completed outside the sandbox, including icon generation, all 73 linked module license references, and strict ad-hoc signature verification. The bundled Go helpers were reused from the previously validated build; authentication and recovery engines were not changed in this release. Earlier validation below describes earlier versions.

## Installable package

The earlier `dist/AppStore++-1.2.0-AppleSilicon.pkg` expands successfully. All 99 app files match the verified build byte-for-byte; the expanded app passes deep/strict ad-hoc signature validation. Package version 1.2.0 and the fixed `/Applications` destination were checked. There are no installation scripts. This package has been created and inspected, not installed over the user's running copy. The current installer is unsigned and not notarized.

`dist/AppStore++-1.1.0-AppleSilicon.pkg` is a standard unsigned macOS component installer. `pkgutil --expand-full` successfully expands it. Its 98 application files match the verified app byte-for-byte, and the expanded application's ad-hoc signature passes `codesign --verify --deep --strict`. The destination is fixed to `/Applications/AppStore++.app`, with no relocation rules, extra payload, or install scripts. The package does not include account state, captures, models, or downloads. Creating the package did not install or replace an application on the host. Administrator installation has not been executed as part of verification.

Built on an Apple Silicon Mac with macOS build 26A434, using Xcode's Swift compiler and Go 1.26.5.

## Version 1.2.0: native interface and platform selection

The interface uses native tabs, an app results table, a platform menu, and separate Download IPA and Decrypt controls. A separate preview copy was opened and visually inspected; its tvOS menu selection, IPA file chooser, enabled Decrypt action after file selection, and output-folder chooser were exercised. It follows the Mac's system appearance. Download and decrypted-output folders are independent. Regression tests check iOS/iphone, iPadOS/ipad, and tvOS/appletv search and download arguments, clear stale results when switching platforms, and verify that downloads and decrypted output use their respective folders.

## Live recovery and decryption

The saved 26A434 capture successfully recovered using the updated engine. The resulting model was imported into the installed app. A WhatsApp IPA downloaded with the matching account was processed end to end: 16 encrypted images, 56,152 pages, complete=true, all reported cryptid values cleared, and exact mutation-scope checks passed. This is an analysis output, not a signed installable app. The report explicitly sets plaintext_verified=false and signature_verified=false: it checks processing, hashes, mutation scope, and first-page plausibility but does not independently authenticate plaintext correctness or Apple's signature. Private captures, keys, and reports are not included in the app or installer.

## Version 1.1.1: recovery engine update

UnfairPlay was updated by fast-forward from `6ecb0f0` to `102e6ba`. Upstream tests pass for internal/recovery, internal/fairplay, cmd/unfairplay, and tools/compact-kernel, including the exact-reference fallback checks.

## Version 1.1.0: one-click workflow

The shared decryption workflow checks saved models, recovers one automatically when the matching app is installed, or pauses for guided setup and resumes the original target IPA. Downloads use the same workflow. Filenames are generated automatically in the selected output folder. Invalid legacy model selections are cleared without deleting the underlying file.

## Passed

- Native SwiftUI app compiles for arm64, macOS 14+.
- ipatool and UnfairPlay compile from the source snapshots below.
- Native app opens, with the lion-and-cookie icon, sidebar navigation, search screen, and sign-in sheet visible.
- `./test.sh`: missing-license errors show acquisition instructions and the correct App Store page; one-click output naming and retries; download-only behavior; invalid IPA/model rejection; structurally valid but invalid table rejection; clearing invalid legacy model pointers without deleting the source; automatic discovery of installed iOS apps and wrapper bundles; automatic seed download and pending-target resume; missing-model pause; enrollment mismatch routing; failure preserving the original download; JSON search parsing; malformed app rejection; literal shell argument escaping (including apostrophes, newlines, and command substitution text); continuous draining of large helper output; cancellation; mocked 2FA pause, malformed-code validation, rejected-code retry, successful verification, clearing secrets, app search, and sign-out.
- ipatool's mocked Login command tests and AppStore++'s private stdin credential tests pass. No Apple credentials or live Apple authentication are used by those tests.
- The real bundled UnfairPlay `doctor` accepts a synthetic well-formed model and rejects a same-size model with invalid byte tables. These synthetic models are not real enrollment keys.
- AppleScript administrator-command syntax compiles without executing a privileged command.
- Bundled helper help lists the expected commands and the private `--credentials-stdin` integration flag.
- Info.plist validation and ad-hoc code signature verification pass.
- The downloaded Go compiler SHA-256 matches Go's official release metadata: `efb87ff28af9a188d0536ef5d42e63dd52ba8263cd7344a993cc48dd11dedb6a`.

## Requires a user's real account and enrollment

Live sign-in, a matching Overcast download and capture, recovery with the updated engine, and WhatsApp processing were exercised on the user’s Mac. Automated authentication tests still use mock credentials. Live iPadOS/tvOS downloads have not been tested; their selected CLI arguments are covered by regression tests. No passwords or verification codes were requested in chat.

The app accepts the six-digit code provided by Apple. It cannot choose or trigger SMS/email delivery. Email code delivery is not a feature of the bundled ipatool.

The app is ad-hoc signed for local use, not Developer ID signed or notarized. It is not an App Store release.

## Source snapshots

- ipatool: `d9c0247daea564d3ec7d04a9b015d0a29af66b04`
- UnfairPlay: `102e6ba550d69ce604b25ec4b91216d11af0b3c0`

ipatool is modified to accept credential JSON on stdin and to use a separate AppStore++ state directory and Keychain service. Upstream notices and 73 linked Go module references are included in the packaged app. The icon was generated with the built-in imagegen tool; its prompt is saved in Resources/Icon-prompt.txt.
