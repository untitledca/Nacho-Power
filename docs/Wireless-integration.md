# EcoFlow wireless monitoring

## Supported Bluetooth path

The native CoreBluetooth monitor supports DELTA 3 (`P231`) and DELTA 3 Plus (`P351`) with encryption type 7. It discovers the serial from EcoFlow manufacturer advertisements, opens the advertised GATT service, establishes a secp160r1 ECDH session, and authenticates with the existing owner's EcoFlow account identity. Setup reuses the local official app's account identity when available; normal EcoFlow email/password sign-in is the fallback. Users do not need to find or enter a numeric account ID. The password and returned login tokens are not saved. Only the account identifier is retained in macOS Keychain. Subsequent Bluetooth monitoring works without internet.

The official EcoFlow app must be closed before connecting. The app refuses to contend with a running EcoFlow app or PowerManager. Bluetooth denial, disabled Bluetooth, connection timeouts, unsupported firmware, multiple stations, and wrong account IDs produce actionable connection errors. A serial filter selects one station when multiple are nearby. All session keys are discarded on disconnect; failed connections back off before retrying. The client never binds/unbinds devices or changes power outputs, charging, time, or Wi-Fi settings.

Incoming DELTA telemetry is protobuf `DisplayPropertyUpload`: battery field 262 (fallback main battery field 242), total input watts field 3, AC input watts field 54, and explicit AC charger presence field 202. Unknown or missing fields are not zeros. Packet lengths, CRC8/CRC16, field types, numeric ranges, and AES framing are validated. The serial and account ID are never included in the public diagnostics.

In v1.3.1, early telemetry received during owner authentication is buffered and exposed only after a successful owner-authentication acknowledgment. A failed or abandoned authentication discards the buffered values. This prevents a valid early AC update from being lost while keeping unauthenticated readings out of the UI and reminder engine.

The monitor merges incremental updates within one session. Once an explicit AC state is known, later updates that omit that field leave it unchanged while the authenticated stream remains live; the AC flag no longer expires merely because 90 seconds have passed without that same field repeating. An explicit later AC update replaces it immediately. Disconnects, stopped monitoring, and stalled telemetry clear the session values before reconnecting. A new session begins with unknown AC until it receives an explicit flag or a usable runtime AC-input voltage reading. Zero AC watts, combined solar/DC input, or battery data alone never supply a missing AC-presence flag.

The stream must deliver recognized telemetry containing at least one battery, AC-presence, AC-watts, total-watts, or valid runtime AC-input voltage field within each 15-second interval. Without it, the monitor clears the session and reconnects; unrelated notifications do not keep old AC state alive. Successful owner authentication starts an initial 15-second grace period only when no telemetry has arrived yet. Buffered readings keep their actual observation timestamps: a late acknowledgment cannot make stale data fresh. Battery percentage and wattage fields still expire individually after 90 seconds without being supplied again.

## New-firmware runtime voltage fallback (v1.3.2)

New DELTA 3 Plus firmware can omit display field 202 entirely. In that case, after owner authentication succeeds, the monitor requests a runtime status report every two seconds. Each request contains only `ConfigWrite.active_runtime_property_full_upload` field 72 set to true (payload `c0 04 01`), with packet version `0x13`, source `0x21`, destination `0x02`, source/destination subaddresses 1, command set `0xFE`, and command ID `0x11`. It uses the existing encrypted session and a normal packet CRC. Source `0x20` requests produced no runtime report on the tested updated station; the authenticated source `0x21` works. The request asks for one report and does not change a persistent setting.

The response is `RuntimePropertyUpload` (`0xFE/0x16`). Only its float field **68**, AC-input voltage in volts, supplies the fallback. Output voltage (field 67), AC flow state (display field 47), and wattage do not establish input-cable presence. The observed flow value 12 appeared both with AC plugged in at zero watts and while unplugged.

A fresh voltage from 0 through 10 V means AC disconnected, allowing for the roughly 1–2 V residual reported during the physical unplug test. A reading from 80 through 300 V means AC connected; voltages above 10 V and below 80 V remain unknown. Nonfinite or out-of-range values are rejected. Voltage expires independently after six seconds even if battery telemetry keeps arriving, so a missing runtime response cannot preserve an old voltage-derived AC state. Explicit display field 202 always takes priority when available and stops runtime polling. Requests also stop on disconnect, failed authentication, or stopped monitoring. Polls skip when a previous Bluetooth write is still pending, and sending a request never refreshes received-telemetry liveness.

## Gray AC status over Bluetooth

A battery percentage alongside **AC status unavailable** means recognized telemetry has arrived but the app has neither a reliable explicit AC flag nor a fresh, usable runtime AC-input voltage. A successful EcoFlow sign-in is account setup; it does not establish that station authentication or AC telemetry has succeeded. When a fresh session supplies neither field 202 nor usable runtime voltage, the app preserves unknown AC instead of guessing plugged or unplugged from watts. Install v1.3.2 or later for the runtime fallback on updated firmware.

Close the official EcoFlow app, wait briefly for the initial readings, and use **Save & connect** to start a fresh session if needed. If the icon remains gray, the useful diagnostic details are the exact station model and firmware, the connection source shown in Settings, and the displayed status or connection error. A gray icon with no battery percentage can instead indicate discovery, authentication, Bluetooth permission, or connection failure.

## Wi-Fi cloud path

Wi-Fi uses the EcoFlow Developer HTTPS API, not an unverified direct-LAN protocol. It requires internet, a station already configured for Wi-Fi in the official app, its serial, and EcoFlow Developer access/secret keys. Keys are held in macOS Keychain. Requests are signed with HMAC-SHA256 using the published EcoFlow algorithm. Only `GET /iot-open/sign/device/list` and `GET /iot-open/sign/device/quota/all` are used, with a five-second minimum interval. The list's online state is checked before trusting quota data.

Cloud readings can lag the station. The cloud API does not provide a universal per-field device timestamp, so the UI explicitly identifies this as cloud telemetry that may be delayed. Some accounts/devices are not granted quota API access; a returned restriction is reported rather than bypassed. Bluetooth and USB are preferred for immediate physical AC transitions. Wi-Fi cloud was validated with signing/parser fixtures, not a live developer account in this session.

Automatic mode tries USB, then configured Bluetooth, then configured Wi-Fi cloud. Missing configuration is not a disconnection event. A source failure never invents an AC-unplug event.

## Validation on this laptop

On 2026-10-14, after closing the official EcoFlow app, the native Bluetooth implementation discovered the user's DELTA 3 Plus, completed ECDH and owner authentication, and repeatedly read 97.965% battery, AC presence true, and AC input 0 W. The installed app also connected successfully and showed the correct DELTA 3 Plus name and 98% battery. This confirms connected-at-zero-watts behavior. The user subsequently confirmed a physical AC unplug/reconnect cycle with v1.3.1: red icon and cat while unplugged, then green icon and immediate cat dismissal after reconnecting.

On the same DELTA 3 Plus after its firmware update, the old display AC flag was absent. Authenticated runtime requests returned about 121 V while connected, 1.13–1.87 V during more than 30 seconds with the AC input physically unplugged, and about 121 V after reconnecting. These readings establish the new fallback against a physical cable cycle, rather than inferred charging watts. The affected firmware version was reported as V7.73.86.37; compatibility with every firmware variant is not established.

Deterministic session tests cover early telemetry withheld until owner authentication succeeds, a late acknowledgment leaving stale data unavailable, failed-session reset, explicit AC transitions at 0 W, AC retention beyond 90 seconds of incremental battery updates, individual battery/wattage expiration, a stalled stream, and a new session with no inherited AC state. Missing initial AC stays unknown even with positive input watts. Runtime fallback tests additionally cover authenticated polling, exact request bytes and CRC, 121 V/near-zero transitions, threshold boundaries, ambiguous and invalid voltage, field 67 rejection, six-second expiry during continued battery updates, and legacy AC-flag priority. These tests verify parsing and session behavior; they do not establish compatibility with every firmware or replace a physical unplug/reconnect test.

## Provenance

- [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble), revision `71f5b90a23dce7acdf7b8d701460de59f6d3b0f6`, Apache-2.0: advertisement layout, session exchange, framing, session table, and DELTA protobuf fields. The Swift implementation includes only read/session operations. `Sources/EcoFlowSessionKeyData.swift` contains the required protocol table, not user credentials.
- [micro-ecc](https://github.com/kmackay/micro-ecc), revision `541b3a78026420a3e369c4c9281c396b5e531113`, BSD-2-Clause: secp160r1 implementation required by the existing EcoFlow BLE protocol. It is compiled into both architectures; no external runtime is needed.
- [EcoFlow Developer general information](https://developer.ecoflow.com/us/document/generalInfo): public GET endpoints and request-signing algorithm. The tests include EcoFlow's published signature test vector.

The complete redistributable license notices are bundled in `Resources/ThirdPartyNotices.txt`. Tests exercise cryptographic vectors, authentic captured packet grammar, framing/fragmentation, protobuf updates, invalid inputs, and the cloud signature. No real account IDs, API keys, serials, passwords, or login tokens are fixtures.

## Two-station selection (v1.7.0)

Connection settings now lists supported nearby BLE advertisements and connected USB metadata. Discovery does not connect or authenticate. A saved selection remains available when an already-connected station stops advertising. Two-station mode validates distinct, nonempty serials before replacing either applied connection. It can recover the first station's authenticated remembered identity when enabling the second.

Each selected station owns a connection monitor, CBCentralManager, peripheral/session state, cloud cache, USB queue, cancellation generation, telemetry, and reconnect task. USB targets the selected station's reported serial; CDC input watts are read only from a port under that exact USB device parent. The primary remembered-station Keychain key is unchanged; secondary station memory uses an account-scoped secondary key. Diagnostic events identify only fixed primary/secondary slots, with station identifiers still excluded.

Two local station sessions do not add multi-controller support to an individual EcoFlow. Close other apps holding either station's connection. Both Bluetooth stations must accept the saved owner's account identity. Pure tests cover isolation and aggregation; simultaneous two-station hardware execution remains unverified in this release session.
