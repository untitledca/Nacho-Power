# Nacho Power

<img src="Resources/NachoPowerLogo.png" width="180" alt="Nacho Power logo">

A Mac app that reminds you to reconnect your EcoFlow to AC power. It can monitor one or two stations and shows each battery percentage in the Dock and plays a transparent cat above your desktop when AC is disconnected. By default, clicks and keystrokes continue to reach the apps behind the cat. Optional timed reminders let you click the cat to snooze it.

The Dock icon and menu-bar battery indicator are **green when AC is connected** and **red when AC is disconnected**. It shows an unknown state when a reliable connection or AC reading is unavailable. A fully charged station can be green even while drawing 0 W.

The app includes left- and right-side cat videos and the logo. No Terminal, developer tools, PowerManager, or additional drivers are needed to run the installed app. Wireless setup has the account requirements described below; USB does not require an account.

## Install

Download the universal DMG from this repository's Releases page. Open it, drag **Nacho Power.app** into **Applications**, eject the disk image, and open the installed app. Click its Dock icon or menu-bar icon to open Settings, preview the cat, or quit.

Nacho Power was previously named **EcoFlow Cat**. When upgrading an older installation, quit EcoFlow Cat before opening Nacho Power. Your settings and saved EcoFlow sign-in are preserved. After installing Nacho Power, remove the old **EcoFlow Cat.app** from Applications to avoid launching both copies and competing for the station's connection.

The distributed app is ad-hoc signed and is not notarized by Apple. If macOS blocks it, follow [Apple's instructions for opening an app you trust](https://support.apple.com/en-us/102445).

Requires macOS 14 or newer. The app contains native Apple silicon and Intel binaries.

## Updates

Starting with **v1.4.0**, Nacho Power can check, download, install, and relaunch itself using Sparkle. Open **Settings → App updates**:

- **Check automatically for updates** enables daily checks while the app is running. A due check also runs after launch.
- **Download and install updates automatically** also enables checks. New updates download in the background, then install and relaunch when Settings is closed and no cat reminder or preview is active. Settings and saved EcoFlow sign-in are preserved.
- **Check for Updates** checks immediately and lets you install through the updater's window.

Both automatic options are off on a fresh install until selected. An existing automatic-check preference is preserved as **checking only**; it never silently enables installation. Turning off automatic checks also turns off automatic downloading. Turning off automatic installation stops future automatic downloads and automatic relaunches. An update already downloaded and ready may still install when you quit normally; Settings shows that state.

**Users on v1.3.3 or earlier must [download and install v1.4.0 or later](https://github.com/untitledca/Nacho-Power/releases/latest) once** to get the automatic installer. Their existing Check for Updates button can find the new DMG, but those older copies still need the drag-to-Applications step.

Update feeds and installers are verified using the app's pinned Ed25519 public key before extraction. Checks and downloads use public GitHub URLs; EcoFlow credentials, station telemetry, and payment information are not sent. Install the app in Applications first. macOS may require administrator approval if the installed app cannot be replaced by your user account.

Release maintainers: every new release must include a signed `appcast.xml` alongside the DMG. See [Publishing updates](docs/Publishing-updates.md).

## Support Nacho Power

If you like the app, **Support Nacho Power** in Settings or the menu bar opens the same optional **$5 / $10 / $25 USD** QuickBooks checkouts used on the [Atom Film Lab Apps page](https://www.atomfilmlab.com/apps). Each is a one-time payment to Atom Film Lab Inc.; review the checkout before paying. Nacho Power remains free, and support does not unlock features.

## Connect and use

**Quit the official EcoFlow app before connecting Nacho Power.** It can hold the station's Bluetooth or Wi-Fi connection. Quit PowerManager as well when using USB.

Open **Connection settings**, choose a transport, enter any required details, and select **Save & connect**:

- **USB:** Connect the station's USB data connection to your Mac. No cloud account or internet access is needed.
- **Bluetooth:** Allow Nacho Power to use Bluetooth when macOS asks. It automatically finds your nearby supported DELTA and uses the account identity from a signed-in official EcoFlow app on this Mac when available. If account setup is needed, use **Sign in for Bluetooth** with your normal EcoFlow email and password. You do not need to find or type a numeric account code. This mode is a direct local connection and does not need internet after setup. Use **Find nearby stations** and the **Station 1** picker to select a specific unit. Manual serial entry remains available if the station is not advertising.

After a successful Bluetooth authentication, Nacho Power remembers that station for the signed-in account in this Mac's Keychain. Reconnects wait for the same station, including after restarting the app, instead of switching to another nearby DELTA. An explicit serial number overrides the remembered station. Unsupported neighboring products and repeated advertisements for the same station do not create a multiple-station selection error. If several compatible stations are found before the first successful connection, choose the intended station under **Connection settings → Find nearby stations → Station 1**, then **Save & connect**.

On a shared set, another person's EcoFlow or Nacho Power app may compete for the same station's Bluetooth connection. The app cannot detect or close another device's apps, force a busy station to accept a connection, or guarantee that multiple controllers can monitor the same station simultaneously. Use one Bluetooth controller per station at a time. When readings stop, battery/AC status remains unknown until fresh authenticated readings return; this must not trigger a false unplugged reminder. A specific station selection prevents a reconnect from drifting to someone else's battery.
- **Wi-Fi (cloud):** Keep the station online through Wi-Fi. Enter its serial number, account region, and your EcoFlow developer access and secret keys. This mode uses EcoFlow's cloud API and requires internet access; it does not provide an offline connection to a station's Wi-Fi hotspot.
- **Automatic:** Tries USB first, then Bluetooth, then configured Wi-Fi cloud access. This is the default connection mode.

The app stores the discovered or signed-in Bluetooth account identity and cloud API keys in this Mac's Keychain. The optional sign-in helper sends your password directly to EcoFlow over HTTPS for that request and never saves it. Subsequent Bluetooth connections use the stored account ID. Settings show the battery, input power, AC state, and connection errors.

### Monitor two EcoFlows

Starting with **v1.7.0**, open **Connection settings**, select **Find nearby stations**, choose **Station 1**, enable **Monitor a second EcoFlow**, and choose a different **Station 2**. Select each transport and press **Save & connect**. Each station has its own battery, AC state, errors, connection, and reconnect loop. Nearby Bluetooth and connected USB devices are listed with a short serial suffix; the current saved selection remains available even when it stops advertising. You can also enter each serial manually. Two-station mode requires two distinct explicit station selections; an invalid selection leaves the current connections running.

Both percentages appear in the menu bar in station order. The Dock has separate **1** and **2** badges, each green, red, or gray for that station's AC state. Percentages are never averaged. Each station has its own battery condition and reminder countdown; either can trigger the shared cat. Reconnecting one station does not dismiss the cat while the other still has an active reminder. In timed mode, clicking the cat snoozes both eligible stations for a full selected interval.

Bluetooth stations must both be accessible to the saved EcoFlow account. Cloud mode shares the configured developer credentials and region, with a separate serial for each station. USB selection requires the station to report its serial over USB. These features do not let another app share a station's occupied Bluetooth connection.

The default reminder setting is **When unplugged**: a fresh, reliable AC-disconnected reading starts the intro once, followed by the loop repeating. **Bottom left** and **Top left** use `intro_left.mov` and `looping_left.mov`, where the cat enters from the left. **Bottom right** and **Top right** keep the original `intro.mov` and `loop.mov`. Reconnecting AC on the last station with an active reminder interrupts either video immediately and removes the cat with a short, approximately 0.18-second pop. It does not wait for charging watts or a separate outro movie. Existing saved battery-threshold preferences remain available; a threshold starts the cat only when the battery is strictly below that value.

With **Fit animation across the entire screen** enabled, choose **From Right** or **From Left**. This direction is saved independently from the smaller corner overlay’s position. Turning full-screen fitting off restores the corner and size controls.

Full-screen fitting preserves the video's proportions within each display. On a portrait monitor, the video fits the screen width and stays at the bottom, leaving transparent space above instead of enlarging and cropping the cat.

Choose **Main display**, a named monitor, or **All displays**. A named monitor is remembered by its display identity, so rearranging screens does not change the selection. If it is disconnected, the cat temporarily uses the main display and returns when the selected monitor reconnects. In All displays mode, each display gets its own transparent cat; a newly connected display joins the current intro or loop. AC reconnection pops all cats away together. macOS handles mirrored displays as a single drawable display.

Audio is muted. **Preview cat** plays the intro and two loops across the selected displays, then pops away; **End preview** dismisses them immediately.

Missing data never counts as an unplug event. A complete telemetry interruption starts a 30-second reminder grace period, then the cat hides. Bluetooth updates can contain only changed fields: a known explicit AC state stays valid while the same authenticated session continues delivering live telemetry. Disconnecting or a stalled stream clears that state before reconnecting. Explicit AC presence is authoritative even at 0 W. Starting with v1.3.2, firmware that omits that flag can use fresh AC-input voltage from an authenticated runtime-status request. Voltage-derived status expires after six seconds without a new voltage reading. Zero watts alone never means the AC cable is unplugged.

**A gray icon with a battery percentage means the app has battery data but no reliable AC status.** Check Settings for **AC status unavailable**. Wait briefly for the station's initial status, then use **Save & connect** with the official EcoFlow app closed. If the status stays unknown, report the station model and firmware, the connection source shown in Settings, and the displayed status. The app keeps AC unknown when neither an explicit AC-presence flag nor a fresh, usable AC-input voltage reading is available, even if the battery percentage is available. On newer DELTA 3 Plus firmware, install v1.3.2 or later to enable the voltage fallback.

## Timed reminders

Use the **Show cat** slider in Settings. Its far-left position, **Immediately**, preserves the original continuous reminder. Move right to choose a delay of **1–60 minutes**. The first countdown starts while fresh EcoFlow readings confirm AC is disconnected and your battery condition is met. The cat enters once and keeps looping until you click it, choose **Snooze** in Settings or the menu bar, or reconnect AC. Snoozing pops the cat away on every selected display and starts a new full interval. AC reconnection clears that station’s countdown and pops away the cat when no other monitored station has an active reminder. Unknown or stale readings cannot start a timed reminder. Existing continuous-reminder preferences start at **Immediately**; saved timed intervals are preserved.

Only the small area surrounding the visible cat captures clicks in timed mode; the remaining desktop stays usable and typing remains with your active app. In continuous mode the entire cat remains click-through. **Preview cat** remains a short manual preview, independent of the timer.

## Troubleshooting and diagnostic reports

Starting with **v1.6.0**, Settings includes **Diagnostics & support**. Reproduce the problem, choose **Export report**, save the text file, and **Review report**. **Email report** opens a draft addressed to **nachopower@atomfilmlab.com** with the report attached when your Mac’s email app supports it. Describe the problem, approximate time, and EcoFlow firmware version, then send the draft yourself. If no email app is configured, attach the saved report using webmail.

The app keeps recent diagnostic events locally in `~/Library/Application Support/Nacho Power/Diagnostics`, limited to two 1 MiB files. Reports contain the app/macOS version, display dimensions, reminder settings, battery/AC readings, connection state, timing, primary/secondary station slots, and numeric protocol field identifiers. Strict allowlists exclude passwords, access keys, account IDs, serial numbers, email addresses, display names/IDs, raw Bluetooth packets, and arbitrary error text. Logs are never uploaded automatically. Export is an explicit action and you can read the file before sharing it. Older app versions cannot provide this history; install v1.6.0 or later and reproduce the issue first.

Standard macOS editing shortcuts—Command+V, Command+C, Command+X, Command+A, and undo/redo—are available through the Edit menu. Secure fields retain macOS restrictions on copying sensitive text.

## Device support and verification

USB monitoring has previously been verified on **DELTA 3 Plus**. It recognizes EcoFlow's USB UPS interface and discovers battery/AC feature fields from its HID descriptor. Other models and firmware are unverified; stations without this USB interface cannot use this USB mode.

The Bluetooth implementation targets **DELTA 3 and DELTA 3 Plus** serial prefixes **P231 / P351** with the supported encrypted BLE protocol. A live Bluetooth session on the project's **DELTA 3 Plus** has authenticated and returned battery percentage plus AC-connected status while drawing **0 W**. The same station has also completed physical AC unplug/reconnect checks. After a firmware update removed its legacy AC flag, v1.3.2 added authenticated runtime-voltage requests, validated against roughly 121 V connected and 1–2 V unplugged. Packet tests cover framing, authentication primitives, and telemetry decoding. These checks do not establish cloud access or compatibility with other stations, account regions, or firmware. Confirm a physical AC-unplug/reconnect cycle on your station before relying on its reminders.

Two-station v1.7.0 regression checks cover explicit selection, USB parent/port binding, discovery deduplication, account/slot isolation, independent AC and battery thresholds, stale readings, timers, snooze, and overlapping pop transitions. Simultaneous live sessions with two physical EcoFlows have not yet been verified in this release session.

Some firmware exposes dedicated AC watts; other firmware exposes combined input only. Settings label the latter **Input power** because solar/DC can contribute to it. An explicit AC-presence flag, or a fresh AC-input voltage reading when that flag is absent, controls the Dock and menu-bar colors and reminder independently of charging power.

The app reads telemetry, requests runtime status when needed, and performs wireless session authentication. It does not change power outputs, charging settings, battery limits, shutdown settings, or the station's Wi-Fi configuration. Native USB implementation details and prior hardware observations are documented in [Direct USB integration](docs/Direct-USB-integration.md). Third-party acknowledgments are included in [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt).

## Build and test

The repository includes all runtime assets. To build from source, install Apple's Command Line Tools, then run:

```sh
Scripts/test.sh
Scripts/build.sh
Scripts/make-dmg.sh
```

For release-maintainer integration testing, `Scripts/test-automatic-installer.sh` uses isolated test apps and a localhost feed to exercise real DMG replacement/relaunch, deferral, and tamper rejection. It requires the existing release signing key in Keychain and never connects to an EcoFlow or modifies the installed app.

The build downloads checksum-pinned Sparkle 2.10.0 once, compiles both architectures, bundles resources and the updater framework, and signs locally. The DMG includes drag-to-Applications installation and a SHA-256 checksum. Developer ID signing and Apple notarization require a suitable certificate and Apple Developer access.

Reminder tests cover thresholds, AC flicker, missing or stale readings, immediate explicit AC changes, and reconnection at zero watts. Native AppKit playback checks cover intro interruption, repeated loops, preview completion, pop timing, restarting during dismissal, and transparent click-through window behavior. Both supplied video pairs have passed a full intro → two loops → pop run. `Scripts/test-display-overlay.sh` is an explicit visual test: it opens real cat windows using simulated monitor geometry. Run it only when ready for visible desktop animations. It covers display targeting, reconnection, mixed resolutions, and one shared preview/dismissal lifecycle. Side-switch tests cover both directions, preserving intro/loop progress, top/bottom moves, rapid changes, and interruption during dismissal.

USB hardware checks are optional: run `Scripts/test.sh --live` with a supported station connected and competing EcoFlow/PowerManager apps closed. Wireless credentials and a physical station are required for live wireless verification.

## Replace the animation

Export `intro.mov` / `loop.mov` for right positions, or `intro_left.mov` / `looping_left.mov` for left positions, as QuickTime ProRes 4444 with actual transparency. Keep the same canvas and frame rate, and match the intro's last frame to the loop's first frame. Then run:

```sh
Scripts/prepare-videos.sh /path/to/right-masters right
Scripts/prepare-videos.sh /path/to/left-masters left
Scripts/build.sh
Scripts/make-dmg.sh
```

Preparation checks decoded alpha pixels in the masters, makes smaller native HEVC files with alpha, then validates the converted files. It preserves the masters and rejects videos without usable transparency. Quit and reopen the app after rebuilding.

Both animation pairs use a **1920 × 1080 canvas at 24 fps**. The right pair has a **20-second intro** and **16.625-second loop**; the left pair has a **10-second intro** and **11.333-second loop**. The left pair adds approximately **5.8 MB** after conversion, with transparency preserved. Dismissal is an AppKit/Core Animation pop, so no outro asset is required.

The logo was generated from the supplied cat photograph using the built-in image generator. The [design prompt](docs/new-name-logo-prompt.txt) and [icon packager](tools/make-app-icon.swift) are included.
