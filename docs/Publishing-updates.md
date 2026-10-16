# Publishing Nacho Power updates

The app uses Sparkle 2.10.0. Its stable feed is the `appcast.xml` asset on the latest published GitHub release:

`https://github.com/untitledca/Nacho-Power/releases/latest/download/appcast.xml`

Every release from v1.4.0 onward must include this file. Keep installers at immutable versioned URLs and do not replace published assets with different bytes.

## Signing key

The Ed25519 private key is stored in the release Mac's login Keychain under Sparkle account **`com.atomfilmlab.nachopower.sparkle`**. It is not stored in the repository, build artifacts, or application. The corresponding public key is `SUPublicEDKey` in `Resources/Info.plist`.

Preserve this Keychain key. Moving release work to a different Mac requires securely transferring the existing key using Sparkle's `generate_keys` export/import support; do not generate a replacement key for an already distributed app. Keep any backup in a password manager or another secure location outside the repository. Losing the key prevents installed copies from trusting future releases.

Sparkle's update signatures are separate from Apple Developer ID signing/notarization. This release remains ad-hoc signed. Keep the current bundle identifier and preferences domain unchanged during updates.

## Build, verify, publish

1. Increment both `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. Sparkle compares the numeric **build version**, so it must increase for every release.
2. Run `Scripts/test.sh`, `Scripts/build.sh`, and `Scripts/make-dmg.sh`. Review the installed build and relevant behavior. The build fetches the official Sparkle archive with a pinned SHA-256 and preserves its nested helper signatures and framework symlinks.
3. Write concise HTML release notes, then run `Scripts/make-appcast.sh /path/to/release-notes.html`. It verifies the Keychain public key matches the app, signs the final DMG, embeds release notes, signs the feed, and verifies its signature. Do not modify the signed feed or installer afterward; regenerate the feed if anything changes.
4. Check the appcast's version, minimum OS, enclosure URL, length, and archive signature. Verify that mounting the DMG yields the expected universal app with the same public key and four cat videos. The generated feed and installed app both require signatures; do not disable those requirements to resolve a publishing error.
5. Commit and tag the tested source. Create a **draft** GitHub release and upload all three assets: `Nacho-Power-VERSION-universal.dmg`, its `.sha256`, and **`appcast.xml`**. Verify uploaded asset sizes and digests match local files before publishing.
6. Publish the release and mark it latest. This makes the complete installer and signed feed available together. Verify the unauthenticated latest-release API, stable feed URL, feed signature, and versioned installer URL.

Keep prereleases separate from the latest stable release. The stable feed must never reference an inaccessible draft asset.

## Consent and installation behavior

Fresh installs default to checks off and installation off. The migration reads the old checking preference only once; existing check-only users never gain automatic installation without selecting it. Sparkle owns its preference persistence and scheduler.

For full automatic updates, the updater retains Sparkle's supported immediate-install closure and runs it only while automatic installation remains enabled, Settings is closed, and the cat overlay is not visible. It then installs and relaunches. A user may choose **Install & Relaunch** explicitly. If automatic updates are turned off after an update is staged, the automatic relaunch stops; Sparkle can still install that staged update on a normal quit. The UI explains this distinction.

Users on v1.3.3 and earlier need one manual install to acquire Sparkle. Preserve the DMG naming convention so their existing GitHub update checker can find that first installer.
