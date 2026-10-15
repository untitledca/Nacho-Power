# EcoFlow wireless monitoring

## Supported Bluetooth path

The native CoreBluetooth monitor supports DELTA 3 (`P231`) and DELTA 3 Plus (`P351`) with encryption type 7. It discovers the serial from EcoFlow manufacturer advertisements, opens the advertised GATT service, establishes a secp160r1 ECDH session, and authenticates with the existing owner's EcoFlow account identity. Setup reuses the local official app's account identity when available; normal EcoFlow email/password sign-in is the fallback. Users do not need to find or enter a numeric account ID. The password and returned login tokens are not saved. Only the account identifier is retained in macOS Keychain. Subsequent Bluetooth monitoring works without internet.

The official EcoFlow app must be closed before connecting. The app refuses to contend with a running EcoFlow app or PowerManager. Bluetooth denial, disabled Bluetooth, connection timeouts, unsupported firmware, multiple stations, and wrong account IDs produce actionable connection errors. A serial filter selects one station when multiple are nearby. All session keys are discarded on disconnect; failed connections back off before retrying. The client never binds/unbinds devices or changes power outputs, charging, time, or Wi-Fi settings.

Incoming DELTA telemetry is protobuf `DisplayPropertyUpload`: battery field 262 (fallback main battery field 242), total input watts field 3, AC input watts field 54, and explicit AC charger presence field 202. Unknown or missing fields are not zeros. Packet lengths, CRC8/CRC16, field types, numeric ranges, and AES framing are validated. The serial and account ID are never included in the public diagnostics.

In v1.3.1, early telemetry received during owner authentication is buffered and exposed only after a successful owner-authentication acknowledgment. A failed or abandoned authentication discards the buffered values. This prevents a valid early AC update from being lost while keeping unauthenticated readings out of the UI and reminder engine.

The monitor merges incremental updates within one session. Once an explicit AC state is known, later updates that omit that field leave it unchanged while the authenticated stream remains live; the AC flag no longer expires merely because 90 seconds have passed without that same field repeating. An explicit later AC update replaces it immediately. Disconnects, stopped monitoring, and stalled telemetry clear the session values before reconnecting. A new session begins with unknown AC until it receives an explicit flag. Zero AC watts, combined solar/DC input, or battery data alone never supply a missing AC-presence flag.

The stream must deliver recognized telemetry containing at least one battery, AC-presence, AC-watts, or total-watts field within each 15-second interval. Without it, the monitor clears the session and reconnects; unrelated notifications do not keep old AC state alive. Successful owner authentication starts an initial 15-second grace period only when no telemetry has arrived yet. Buffered readings keep their actual observation timestamps: a late acknowledgment cannot make stale data fresh. Battery percentage and wattage fields still expire individually after 90 seconds without being supplied again.

## Gray AC status over Bluetooth

A battery percentage alongside **AC status unavailable** means recognized telemetry has arrived but the app has no reliable explicit AC flag. A successful EcoFlow sign-in is account setup; it does not establish that station authentication or AC telemetry has succeeded. When a fresh session never supplies field 202, the app preserves unknown AC instead of guessing plugged or unplugged from watts.

Close the official EcoFlow app, wait briefly for the initial readings, and use **Save & connect** to start a fresh session if needed. If the icon remains gray, the useful diagnostic details are the exact station model and firmware, the connection source shown in Settings, and the displayed status or connection error. A gray icon with no battery percentage can instead indicate discovery, authentication, Bluetooth permission, or connection failure.

## Wi-Fi cloud path

Wi-Fi uses the EcoFlow Developer HTTPS API, not an unverified direct-LAN protocol. It requires internet, a station already configured for Wi-Fi in the official app, its serial, and EcoFlow Developer access/secret keys. Keys are held in macOS Keychain. Requests are signed with HMAC-SHA256 using the published EcoFlow algorithm. Only `GET /iot-open/sign/device/list` and `GET /iot-open/sign/device/quota/all` are used, with a five-second minimum interval. The list's online state is checked before trusting quota data.

Cloud readings can lag the station. The cloud API does not provide a universal per-field device timestamp, so the UI explicitly identifies this as cloud telemetry that may be delayed. Some accounts/devices are not granted quota API access; a returned restriction is reported rather than bypassed. Bluetooth and USB are preferred for immediate physical AC transitions. Wi-Fi cloud was validated with signing/parser fixtures, not a live developer account in this session.

Automatic mode tries USB, then configured Bluetooth, then configured Wi-Fi cloud. Missing configuration is not a disconnection event. A source failure never invents an AC-unplug event.

## Validation on this laptop

On 2026-10-14, after closing the official EcoFlow app, the native Bluetooth implementation discovered the user's DELTA 3 Plus, completed ECDH and owner authentication, and repeatedly read 97.965% battery, AC presence true, and AC input 0 W. The installed app also connected successfully and showed the correct DELTA 3 Plus name and 98% battery. This confirms connected-at-zero-watts behavior. A physical AC unplug/reconnect cycle remains a separate validation step.

Deterministic session tests cover early telemetry withheld until owner authentication succeeds, a late acknowledgment leaving stale data unavailable, failed-session reset, explicit AC transitions at 0 W, AC retention beyond 90 seconds of incremental battery updates, individual battery/wattage expiration, a stalled stream, and a new session with no inherited AC state. Missing initial AC stays unknown even with positive input watts. These tests verify parsing and session behavior; they do not establish compatibility with every firmware or replace a physical unplug/reconnect test.

## Provenance

- [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble), revision `71f5b90a23dce7acdf7b8d701460de59f6d3b0f6`, Apache-2.0: advertisement layout, session exchange, framing, session table, and DELTA protobuf fields. The Swift implementation includes only read/session operations. `Sources/EcoFlowSessionKeyData.swift` contains the required protocol table, not user credentials.
- [micro-ecc](https://github.com/kmackay/micro-ecc), revision `541b3a78026420a3e369c4c9281c396b5e531113`, BSD-2-Clause: secp160r1 implementation required by the existing EcoFlow BLE protocol. It is compiled into both architectures; no external runtime is needed.
- [EcoFlow Developer general information](https://developer.ecoflow.com/us/document/generalInfo): public GET endpoints and request-signing algorithm. The tests include EcoFlow's published signature test vector.

The complete redistributable license notices are bundled in `Resources/ThirdPartyNotices.txt`. Tests exercise cryptographic vectors, authentic captured packet grammar, framing/fragmentation, protobuf updates, invalid inputs, and the cloud signature. No real account IDs, API keys, serials, passwords, or login tokens are fixtures.
