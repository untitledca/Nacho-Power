import Foundation
import Darwin

private enum CheckError: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.failed(message) }
}
private func expectFailure(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckError.failed(message)
}
private func hex(_ string: String) -> [UInt8] {
    let clean = string.filter { !$0.isWhitespace }
    return stride(from: 0, to: clean.count, by: 2).map {
        let a = clean.index(clean.startIndex, offsetBy: $0)
        return UInt8(clean[a..<clean.index(a, offsetBy: 2)], radix: 16)!
    }
}
@_silgen_name("ecoflow_shared_secret")
private func knownSecret(_ publicKey: UnsafePointer<UInt8>, _ privateKey: UnsafePointer<UInt8>, _ secret: UnsafeMutablePointer<UInt8>) -> Int32

@main private enum WirelessProtocolChecks {
    typealias P = EcoFlowWirelessProtocol
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("standard CRC vectors and upstream authentication packet", framingVectors),
            ("NIST AES-CBC, fixed session key, and secp160r1 agreement", cryptoVectors),
            ("fragmented, coalesced, noisy and corrupted Bluetooth frames", frameStream),
            ("captured V19 packets with CRC and XOR payload", capturedPackets),
            ("sentinel V19 packets and malformed packet rejection", sentinelAndMalformedPackets),
            ("protobuf presence, explicit AC at 0 W, and invalid readings", protobufFields),
            ("runtime status request matches the authenticated mobile route", runtimeRequest),
            ("runtime voltage schema, zero volts, and malformed boundaries", runtimeFields),
            ("manufacturer identity, serial selection and encryption flags", advertisements),
            ("station selection ignores neighbors without switching remembered stations", stationSelection),
            ("authenticated station memory is persistent, account-scoped and failure tolerant", stationMemory)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS \(name)") }
            catch { failures += 1; fputs("FAIL \(name): \(error)\n", stderr) }
        }
        print("\(tests.count - failures)/\(tests.count) wireless protocol checks passed")
        if failures != 0 { exit(1) }
    }

    private static func framingVectors() throws {
        // CRC-8/SMBUS and CRC-16/ARC standard check strings.
        try check(P.crc8(Array("123456789".utf8)) == 0xf4, "CRC8 check vector")
        try check(P.crc16(Array("123456789".utf8)) == 0xbb3d, "CRC16 check vector")
        // Serialized independently with upstream Packet(0x21,0x35,0x35,0x89).
        let status = hex("aa030000de0d00000000000021350101358930e4")
        try check(P.authPacket(command: 0x89) == status, "auth status packet byte-for-byte")
        try check(P.wrap(status) == hex("5a5a00011600aa030000de0d00000000000021350101358930e4c102"), "upstream EncPacket wrapper")
        let parsed = try P.parsePacket(status)
        try check(parsed.source == 0x21 && parsed.commandSet == 0x35 && parsed.command == 0x89 && parsed.payload.isEmpty, "auth packet parsing")
    }

    private static func cryptoVectors() throws {
        // NIST SP 800-38A F.2.1 AES-128 CBC first block.
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let clear = hex("6bc1bee22e409f96e93d7e117393172a")
        let ciphertext = hex("7649abac8119b246cee98e9b12e9197d")
        try check(try P.crypt(ciphertext, key: key, iv: iv, encrypt: false) == clear, "NIST decryption")
        let encrypted = try P.crypt(clear, key: key, iv: iv, encrypt: true)
        try check(Array(encrypted.prefix(16)) == ciphertext && encrypted.count == 32, "NIST encryption plus PKCS7 padding")
        try check(try P.crypt(encrypted, key: key, iv: iv, encrypt: false) == clear, "padding removed correctly")
        try check(try P.sessionKey(Array(0...15) + [0, 1]) == hex("cf19aab35c7605235e885521945354d8"), "session key agrees with upstream key table and hashlib")
        try expectFailure("short session seed rejected") { _ = try P.sessionKey([0]) }

        // SEC 2 secp160r1 generator. Private scalar 2 returns the independently computed x-coordinate of 2G.
        let g = hex("4a96b5688ef573284664698968c38bb913cbfc8223a628553168947d59dcc912042351377ac5fb32")
        var privateTwo = [UInt8](repeating: 0, count: 21); privateTwo[20] = 2
        var shared = [UInt8](repeating: 0, count: 20)
        let result = knownSecret(g, privateTwo, &shared)
        try check(result == 1 && shared == hex("02f997f33c5ed04c55d3edf8675d3e92e8f46686"), "secp160r1 network byte order and scalar size (status \(result), known-vector result \(shared.map { String(format: "%02x", $0) }.joined()))")
        let a = try P.KeyExchange(), b = try P.KeyExchange()
        let ab = try a.sharedSecret(peer: b.publicKey), ba = try b.sharedSecret(peer: a.publicKey)
        try check(ab == ba && ab.contains(where: { $0 != 0 }), "fresh ECDH peers agree")
        try expectFailure("invalid curve point rejected") { _ = try a.sharedSecret(peer: [UInt8](repeating: 0, count: 40)) }
    }

    private static func frameStream() throws {
        let command = P.wrap([1, 0, 0] + [UInt8](repeating: 3, count: 40))
        let encrypted = P.wrap([UInt8](repeating: 0x44, count: 32), encrypted: true)
        for split in 0...command.count {
            var stream = P.FrameBuffer()
            var result = try stream.append(Data(command.prefix(split)))
            result += try stream.append(Data(command.dropFirst(split)))
            try check(result.count == 1 && result[0].command && result[0].payload == Array(command[6..<(command.count - 2)]), "fragment split \(split)")
        }
        var stream = P.FrameBuffer()
        let combined = try stream.append(Data([0x31, 0x5a, 0x29] + command + encrypted))
        try check(combined.count == 2 && combined[0].command && !combined[1].command, "coalesced handshake and protocol types preserved")
        var bad = command; bad[bad.count - 1] ^= 1
        let recovery = try stream.append(Data(bad + encrypted))
        try check(recovery.count == 1 && !recovery[0].command, "bad CRC frame cannot poison next good frame")
        // The first 0x5a5a is a corrupt length candidate; recover the later valid frame.
        var noise = P.FrameBuffer()
        let resynced = try noise.append(Data(hex("5a5a00011027") + encrypted))
        try check(resynced.count == 1, "a false long length cannot stall behind a complete valid frame")
    }

    private static func capturedPackets() throws {
        // Captured V19 grammar fixtures from ha-ef-ble 71f5b90, test_delta3_max_plus.py.
        // These exercise the shared packet envelope; they do not claim Max Plus support.
        let captures = capturedV19
        var battery: Double?, total: Double?, connected: Bool?
        for capture in captures {
            let bytes = hex(capture)
            let packet = try P.parsePacket(bytes)
            try check(packet.source == 2 && packet.commandSet == 0xfe && packet.command == 0x15, "captured telemetry routing")
            let update = try P.metrics(packet.payload)
            battery = update.battery ?? battery
            total = update.totalWatts ?? total
            connected = update.acConnected ?? connected
        }
        try check(battery == 99 && total == 0 && connected == false, "captured sample matches upstream expected measurements")
    }

    private static func sentinelAndMalformedPackets() throws {
        // Valid V19 sentinel payload with seq[0] XOR, built from independent wire layout.
        var header = hex("aa130500000d2a000000000002210101fe15")
        header[4] = P.crc8(Array(header.prefix(4)))
        let clear = hex("d00c01bbbb")
        let packet = try P.parsePacket(header + clear.map { $0 ^ 0x2a })
        try check(packet.payload == hex("d00c01"), "decoded sentinel removed after XOR")
        try check(try P.metrics(packet.payload).acConnected == true, "sentinel AC field")
        let status = P.authPacket(command: 0x89)
        for length in 0..<status.count {
            try expectFailure("truncated packet \(length) accepted") { _ = try P.parsePacket(Array(status.prefix(length))) }
        }
        var corrupt = status; corrupt[corrupt.count - 1] ^= 0x80
        try expectFailure("bad CRC accepted") { _ = try P.parsePacket(corrupt) }
        corrupt = status; corrupt[4] ^= 0x01
        try expectFailure("bad header CRC accepted") { _ = try P.parsePacket(corrupt) }
    }

    private static func protobufFields() throws {
        let empty = try P.metrics([])
        try check(!empty.changed && empty.acConnected == nil && empty.battery == nil, "missing fields remain unknown")
        // Fields: AC-present 202=1; AC watts 54=0; total input 3=450; CMS SOC 262=100.
        let full = try P.metrics(hex("d00c01b503000000001d0000e143b5100000c842"))
        try check(full.acConnected == true && full.acWatts == 0 && full.totalWatts == 450 && full.battery == 100, "solar/zero AC watts do not override explicit AC flag")
        let partial = try P.metrics(hex("d00c00"))
        try check(partial.acConnected == false && partial.battery == nil && partial.acWatts == nil, "incremental AC loss does not invent other fields")
        // BMS SOC 242 fallback, then CMS SOC 262 takes priority, in either wire order.
        try check(try P.metrics(hex("950f00002042b51000004842")).battery == 50, "CMS SOC wins after BMS")
        try check(try P.metrics(hex("b51000004842950f00002042")).battery == 50, "CMS SOC wins before BMS")
        let invalid = try P.metrics(hex("d00c02950f0000c07fb5030000807f1d000080bf"))
        try check(!invalid.changed, "nonboolean AC, NaN, infinity and negative watts stay unknown")
        let unknown = try P.metrics(hex("0801a20603616263d00c01"))
        try check(unknown.acConnected == true, "unknown varint/string fields skipped")
        for bytes in [hex("d00c"), hex("b5100000"), hex("a2067f"), [UInt8](repeating: 0xff, count: 10), hex("00"), hex("0b")] {
            try expectFailure("malformed protobuf accepted") { _ = try P.metrics(bytes) }
        }
    }

    private static func advertisements() throws {
        let serial = Array("P351TEST12345678".utf8)
        var advertisement = [UInt8]([0xb5, 0xb5, 3]) + serial + [0, 0, 0, 0, 0, 0x38]
        let parsed = P.Advertisement.parse(Data(advertisement))
        try check(parsed?.serial == "P351TEST12345678" && parsed?.supported == true && parsed?.encryption == 7, "manufacturer prefix and payload offsets")
        advertisement[0] = 0x01
        try check(P.Advertisement.parse(Data(advertisement)) == nil, "foreign manufacturer ignored")
        try check(P.Advertisement.parse(Data([0xb5, 0xb5, 3])) == nil, "truncated advertisement ignored")
    }

    private static func stationSelection() throws {
        let shared = P.Advertisement(serial: "P351SHARED1234567", encryption: 7)
        let neighbor = P.Advertisement(serial: "P231NEARBY1234567", encryption: 7)
        let unsupported = P.Advertisement(serial: "RIVERNEARBY12345", encryption: 7)
        let incompatible = P.Advertisement(serial: "P351SECURE1234567", encryption: 6)
        let sharedSet = [shared, neighbor, unsupported, incompatible]
        try check(P.chooseStation(sharedSet, targetSerial: shared.serial) == .station(shared.serial),
                  "a remembered shared DELTA remains the target with other stations nearby")
        try check(P.chooseStation([neighbor, unsupported, incompatible], targetSerial: shared.serial) == .waiting,
                  "a busy or absent remembered station cannot silently fall back to a neighbor")
        try check(P.chooseStation(sharedSet, targetSerial: nil) == .multiple,
                  "initial setup remains safe when two distinct compatible stations are nearby")
        try check(P.chooseStation([shared, shared, unsupported, incompatible], targetSerial: nil) == .station(shared.serial),
                  "duplicate advertisements of one serial do not count as multiple stations")
        try check(P.chooseStation([shared, unsupported, incompatible], targetSerial: nil) == .station(shared.serial),
                  "unsupported models and incompatible security do not block an available compatible DELTA")
        try check(P.chooseStation([unsupported, incompatible], targetSerial: nil) == .waiting,
                  "an initial scan does not select unsupported neighbors")
        try check(P.chooseStation(sharedSet, targetSerial: unsupported.serial) == .unsupported,
                  "an explicitly targeted unsupported model produces the specific unsupported result")
        try check(P.chooseStation(sharedSet, targetSerial: incompatible.serial) == .incompatibleSecurity,
                  "an explicitly targeted security mismatch produces the specific security result")
        try check(P.chooseStation([shared], targetSerial: " p351shared1234567 \n") == .station(shared.serial),
                  "target matching trims whitespace and ignores serial letter case")
    }

    private static func stationMemory() throws {
        let station = P.Advertisement(serial: "P351SHARED1234567", encryption: 7)
        let other = P.Advertisement(serial: "P231OTHER12345678", encryption: 7)
        var saved: [String: String] = [:]
        var saveCount = 0
        var preference = P.StationPreference()
        preference.configure(accountID: "fixture-owner-A") { saved[$0] ?? "" }
        try check(preference.targetSerial(explicitSerial: "") == nil && saved.isEmpty,
                  "account setup alone cannot remember or persist an unauthenticated advertisement")

        // Route the same owner-acknowledgment cases as the monitor. Neither a
        // rejection nor an unsolicited successful reply reaches the commit.
        var session = EcoFlowBluetoothSessionState()
        func receiveOwner(_ payload: [UInt8], stage: EcoFlowBluetoothSessionState.AuthenticationStage) throws {
            let reply = P.Packet(source: 0x35, commandSet: 0x35, command: 0x86, payload: payload)
            if case .ownerAccepted = try session.receive(reply, stage: stage, at: Date(timeIntervalSince1970: 100)) {
                preference.rememberAuthenticated(station) { value, key in saved[key] = value; saveCount += 1 }
            }
        }
        try expectFailure("rejected owner authentication must fail") {
            try receiveOwner([1], stage: .awaitingOwnerAcknowledgment)
        }
        try receiveOwner([0], stage: .awaitingStatus)
        try check(preference.rememberedSerial.isEmpty && saved.isEmpty && saveCount == 0,
                  "failed or unsolicited authentication cannot remember a station")
        try receiveOwner([0], stage: .awaitingOwnerAcknowledgment)
        try check(preference.rememberedSerial == station.serial && saveCount == 1,
                  "only accepted owner authentication commits the station")
        let accountAKey = preference.accountKey
        try check(preference.targetSerial(explicitSerial: " \n") == station.serial,
                  "ordinary reconnects keep the authenticated target")
        try check(preference.targetSerial(explicitSerial: " p231other12345678 ") == other.serial,
                  "an explicit station overrides memory without replacing it before authentication")
        try check(preference.rememberedSerial == station.serial, "selecting another station cannot itself change authenticated memory")
        var relaunched = P.StationPreference()
        relaunched.configure(accountID: "fixture-owner-A") { saved[$0] ?? "" }
        try check(relaunched.targetSerial(explicitSerial: "") == station.serial,
                  "relaunch loads the same authenticated station through injected persistence")
        relaunched.configure(accountID: "fixture-owner-B") { saved[$0] ?? "" }
        try check(relaunched.rememberedSerial.isEmpty && relaunched.accountKey != accountAKey,
                  "changing accounts cannot inherit the previous account's target")
        relaunched.rememberAuthenticated(other) { value, key in saved[key] = value }
        relaunched.configure(accountID: "fixture-owner-A") { saved[$0] ?? "" }
        try check(relaunched.rememberedSerial == station.serial,
                  "returning to an account restores that account's own station")
        relaunched.rememberAuthenticated(other) { _, _ in throw CheckError.failed("simulated locked Keychain") }
        try check(relaunched.rememberedSerial == other.serial,
                  "a persistence failure retains the authenticated in-memory station without throwing")
        relaunched.configure(accountID: "  ") { _ in throwUnexpectedLoad() }
        try check(relaunched.accountKey == nil && relaunched.rememberedSerial.isEmpty,
                  "signing out clears station memory and never reads a global fallback")
        try check(P.stationAccountKey(" abc\n") == "bluetooth.station.v1.ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                  "account keys use trimmed account IDs and a known SHA-256 vector")
        try check(!(accountAKey ?? "").contains("fixture-owner-A"), "persistence keys contain no raw account identifier")
    }

    private static func throwUnexpectedLoad() -> String {
        preconditionFailure("An empty account must not read station persistence")
    }

    private static func runtimeRequest() throws {
        // Independently serialized using upstream Packet(0x21,0x02,0xFE,0x11,
        // bytes.fromhex("c00401"),1,1,0x13); the live DELTA accepts source 0x21.
        let expected = hex("aa130300430d00000000000021020101fe11c004013e18")
        let bytes = P.runtimeUploadRequest()
        try check(bytes == expected, "exact one-shot runtime upload request")
        try check(P.crc8(Array(bytes.prefix(4))) == bytes[4] && P.crc16(bytes) == 0, "request header and trailing checksums")
        try check(bytes[1] == 0x13 && bytes[13] == 2 && bytes[14] == 1 && bytes[15] == 1, "V19 EMS destination and device routing")
        let packet = try P.parsePacket(bytes)
        try check(packet.source == 0x21 && packet.commandSet == 0xfe && packet.command == 0x11, "authenticated mobile request route")
        try check(packet.payload == hex("c00401"), "only field72=true, no display trigger or persistent setting")

        let key = [UInt8](repeating: 1, count: 16), iv = [UInt8](repeating: 2, count: 16)
        let encrypted = try P.crypt(bytes, key: key, iv: iv, encrypt: true)
        let frame = P.wrap(encrypted, encrypted: true)
        try check(Array(frame.prefix(4)) == hex("5a5a1001"), "standard encrypted protocol wrapper")
        var stream = P.FrameBuffer()
        let frames = try stream.append(Data(frame))
        try check(frames.count == 1 && !frames[0].command, "runtime request is a protocol frame")
        try check(try P.crypt(frames[0].payload, key: key, iv: iv, encrypt: false) == expected, "runtime request survives encryption and framing")
    }

    private static func runtimeFields() throws {
        // Field68 fixed32 float=121 V, then explicit zero. Zero must be present.
        let mains = try P.runtimeMetrics(hex("a5040000f242"))
        let disconnected = try P.runtimeMetrics(hex("a50400000000"))
        try check(mains.changed && mains.acInputVoltage == 121, "AC input volts accepted")
        try check(disconnected.changed && disconnected.acInputVoltage == 0, "explicit zero volts retained")
        try check(!P.runtimeMetrics([]).changed, "missing voltage remains unknown")
        try check(try P.runtimeMetrics(hex("a50400009643")).acInputVoltage == 300, "upper voltage bound accepted")
        // AC-output voltage67, display SOC262, watts54/3, and flag202 are not
        // runtime mains evidence, even when their values look plausible.
        let unrelated = hex("9d040000f242b5100000c842b5030000c8431d0000c843d00c01")
        try check(try !P.runtimeMetrics(unrelated).changed, "output voltage and display fields ignored")
        try check(try P.runtimeMetrics(unrelated + hex("a5040000f242")).acInputVoltage == 121, "unknown fields do not hide valid AC input")
        try check(try !P.metrics(hex("a5040000f242")).changed, "runtime field cannot be decoded as display data")
        // NaN, +infinity, -infinity, -1, and 301 V are invalid observations.
        for bits in ["0000c07f", "0000807f", "000080ff", "000080bf", "00809643"] {
            try check(try !P.runtimeMetrics(hex("a504" + bits)).changed, "invalid voltage ignored: \(bits)")
        }
        for bytes in [hex("a504"), hex("a5040000"), hex("a2047f"), hex("a1040000"),
                      hex("a004"), [UInt8](repeating: 0xff, count: 10), hex("00"), hex("0b")] {
            try expectFailure("malformed runtime protobuf accepted") { _ = try P.runtimeMetrics(bytes) }
        }
        try check(try !P.runtimeMetrics(hex("a00401")).changed, "wrong wire type cannot become voltage")
    }

    private static let capturedV19: [String] = [
        "aa13ff00ab0d4cb80400000002210101fe15444c64cc4d744c0c7ec44d4cdc4de04ed44d4cec4d4c844d4ca64b6c464a444d5c4d5444464a444d5c4f545e464a444e5c4d5444464a444e5c4f545ee4444cfe444b09382f6319180ff4444dac444cdc454cd4454cfc474dd4404cd44170ec414ce4414c96414cd4424dd9434c4c8a0ed1434c4c840e8c438cf44ebc43b308b443b328dc5c59d45c5aec5c54e45c56f95c4c4c8a0ef15c4c4c840eac5cb308a45cb328bc5c28b45c4cd45d4d845d4c9c5d4cd45a4ca4544cbc544ce4574cfc574cf4574cdc504c9450f45bac50ec4abc50b153d4514dec514ce4519cfc9d804ab470caccc844ce715c464a44b3b3b3b343464a44b3b3b3b343c4714cec174c3ae9",
        "aa133c017e0d4db80400000002210101fe15504d4d4d4d684d4d4d4d004d4d4d4d184d4d4d4d104d4d4d4d284d4d4d4d25433d4d3543cd4c43c54f49e04f4d4d4d4da54f41bd4f4bb54f41e04e4d4d4d4df84e4d4d4d4df8494d4d4d4da0494d4d4d4dbd494db5494dc54845dd4871e84b4d4d4d4d8f45414749454c5d454749454e5d5f8745414749454c5d454749454e5d5fb5454dcd4459c544298d4443854443b8444d4d4d4dcd5c59c55c17dd5c4ca55c4dbd5c4d805f4d4d3d8c8d5b41805b4d4d4d4d9d5b4c955b4dad5b4ca55b45bd5b71b55b43c85a4d4d4d4d87554d9d554d95554dad554dbd5441e5574cfd574df5574d8d574d80574d4d4d4dbd574c8d514da5517f8f715947495d4c555447495d4f5554474b454c5d4e556c87714747454d4d4d4d4d4d4d4d957143af715b47594d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4dd57043b5024c7b75",
        "aa13c200bb0d4eb80400000002210101fe15be4f4ea64d4ebe4d7cd64b4eee4b4ee64b4efe4b4ef64b4e8c4b5e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e864b4e9e4bd3cece56944b5c445e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4eae494ebc464e9e424ec643ee48de404ebe40f6599e544f965417ae544ab6544ccc5569446bceced6d84aceceeed84a4ef9f64c8ef64ce6f84c4e4e4e4e4e4eb4d7b629deec8ade4f4f4ec4555e0a7d0b7f1a0b1d1a7f7c7d7a7b787976de55d3cece56d6554eee554c9e52ae5c9b6b4e4e4e4ec6014ed62e4febd6",
    ]
}
