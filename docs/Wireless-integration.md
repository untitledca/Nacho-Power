# EcoFlow wireless monitoring

## Supported Bluetooth path

The native CoreBluetooth monitor supports DELTA 3 (`P231`) and DELTA 3 Plus (`P351`) with encryption type 7. It discovers the serial from EcoFlow manufacturer advertisements, opens the advertised GATT service, establishes a secp160r1 ECDH session, and authenticates with the existing owner's EcoFlow account identity. Setup reuses the local official app's account identity when available; normal EcoFlow email/password sign-in is the fallback. Users do not need to find or enter a numeric account ID. The password and returned login tokens are not saved. Only the account identifier is retained in macOS Keychain. Subsequent Bluetooth monitoring works without internet.

The official EcoFlow app must be closed before connecting. The app refuses to contend with a running EcoFlow app or PowerManager. Bluetooth denial, disabled Bluetooth, connection timeouts, unsupported firmware, multiple stations, and wrong account IDs produce actionable connection errors. A serial filter selects one station when multiple are nearby. All session keys are discarded on disconnect; failed connections back off before retrying. The client never binds/unbinds devices or changes power outputs, charging, time, or Wi-Fi settings.

Incoming DELTA telemetry is protobuf `DisplayPropertyUpload`: battery field 262 (fallback main battery field 242), total input watts field 3, AC input watts field 54, and explicit AC charger presence field 202. Unknown or missing fields are not zeros. The monitor merges incremental updates only within one live authenticated session. Individual retained fields expire after 90 seconds; no telemetry for 15 seconds causes reconnection. Packet lengths, CRC8/CRC16, field types, numeric ranges, and AES framing are validated. The serial and account ID are never included in the public diagnostics.

## Wi-Fi cloud path

Wi-Fi uses the EcoFlow Developer HTTPS API, not an unverified direct-LAN protocol. It requires internet, a station already configured for Wi-Fi in the official app, its serial, and EcoFlow Developer access/secret keys. Keys are held in macOS Keychain. Requests are signed with HMAC-SHA256 using the published EcoFlow algorithm. Only `GET /iot-open/sign/device/list` and `GET /iot-open/sign/device/quota/all` are used, with a five-second minimum interval. The list's online state is checked before trusting quota data.

Cloud readings can lag the station. The cloud API does not provide a universal per-field device timestamp, so the UI explicitly identifies this as cloud telemetry that may be delayed. Some accounts/devices are not granted quota API access; a returned restriction is reported rather than bypassed. Bluetooth and USB are preferred for immediate physical AC transitions. Wi-Fi cloud was validated with signing/parser fixtures, not a live developer account in this session.

Automatic mode tries USB, then configured Bluetooth, then configured Wi-Fi cloud. Missing configuration is not a disconnection event. A source failure never invents an AC-unplug event.

## Validation on this laptop

On 2026-10-14, after closing the official EcoFlow app, the native Bluetooth implementation discovered the user's DELTA 3 Plus, completed ECDH and owner authentication, and repeatedly read 97.965% battery, AC presence true, and AC input 0 W. The installed app also connected successfully and showed the correct DELTA 3 Plus name and 98% battery. This confirms connected-at-zero-watts behavior. A physical AC unplug/reconnect cycle remains a separate validation step.

## Provenance

- [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble), revision `71f5b90a23dce7acdf7b8d701460de59f6d3b0f6`, Apache-2.0: advertisement layout, session exchange, framing, session table, and DELTA protobuf fields. The Swift implementation includes only read/session operations. `Sources/EcoFlowSessionKeyData.swift` contains the required protocol table, not user credentials.
- [micro-ecc](https://github.com/kmackay/micro-ecc), revision `541b3a78026420a3e369c4c9281c396b5e531113`, BSD-2-Clause: secp160r1 implementation required by the existing EcoFlow BLE protocol. It is compiled into both architectures; no external runtime is needed.
- [EcoFlow Developer general information](https://developer.ecoflow.com/us/document/generalInfo): public GET endpoints and request-signing algorithm. The tests include EcoFlow's published signature test vector.

The complete redistributable license notices are bundled in `Resources/ThirdPartyNotices.txt`. Tests exercise cryptographic vectors, authentic captured packet grammar, framing/fragmentation, protobuf updates, invalid inputs, and the cloud signature. No real account IDs, API keys, serials, passwords, or login tokens are fixtures.
