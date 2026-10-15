import Foundation
import CommonCrypto
import CryptoKit

@_silgen_name("ecoflow_make_key")
private func makeEcoFlowKey(_ publicKey: UnsafeMutablePointer<UInt8>, _ privateKey: UnsafeMutablePointer<UInt8>) -> Int32
@_silgen_name("ecoflow_shared_secret")
private func makeEcoFlowSecret(_ publicKey: UnsafePointer<UInt8>, _ privateKey: UnsafePointer<UInt8>, _ secret: UnsafeMutablePointer<UInt8>) -> Int32

enum EcoFlowWirelessError: LocalizedError {
    case message(String)
    case invalidPacket
    case unsupportedDevice
    case authentication
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .invalidPacket: return "The EcoFlow sent an unreadable wireless reading."
        case .unsupportedDevice: return "Bluetooth currently supports DELTA 3 / DELTA 3 Plus (P231 / P351). Use USB for other models."
        case .authentication: return "Bluetooth authentication failed. Check the EcoFlow account user ID and close the EcoFlow app."
        }
    }
}

/// Only session setup/authentication, telemetry requests and incoming readings are implemented.
/// There are no device settings, power-output, Wi-Fi provisioning, or bind writes.
enum EcoFlowWirelessProtocol {
    struct Advertisement {
        let serial: String
        let encryption: UInt8
        var deviceName: String { serial.hasPrefix("P351") ? "EcoFlow DELTA 3 Plus" : "EcoFlow DELTA 3" }
        static func parse(_ data: Data) -> Advertisement? {
            let b = [UInt8](data)
            // CoreBluetooth includes the two-byte manufacturer ID; Bleak omits it.
            guard b.count >= 19, b[0] == 0xb5, b[1] == 0xb5,
                  let sn = String(bytes: b[3..<19].prefix(while: { $0 != 0 }), encoding: .ascii),
                  sn.count >= 4 else { return nil }
            return Advertisement(serial: sn, encryption: b.count > 24 ? (b[24] >> 3) & 7 : 7)
        }
        var supported: Bool { serial.hasPrefix("P351") || serial.hasPrefix("P231") }
    }

    struct Packet {
        let source: UInt8
        let commandSet: UInt8
        let command: UInt8
        let payload: [UInt8]
    }

    static func crc8(_ data: [UInt8]) -> UInt8 {
        data.reduce(0) { previous, byte in
            var value = previous ^ byte
            for _ in 0..<8 { value = value & 0x80 != 0 ? (value &<< 1) ^ 0x07 : value &<< 1 }
            return value
        }
    }
    static func crc16(_ data: [UInt8]) -> UInt16 {
        data.reduce(0) { previous, byte in
            var value = previous ^ UInt16(byte)
            for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xa001 : value >> 1 }
            return value
        }
    }
    static func wrap(_ payload: [UInt8], encrypted: Bool = false) -> [UInt8] {
        let count = payload.count + 2
        var bytes: [UInt8] = [0x5a, 0x5a, encrypted ? 0x10 : 0, 1,
                              UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)] + payload
        let crc = crc16(bytes)
        bytes += [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
        return bytes
    }
    static func authPacket(command: UInt8, payload: [UInt8] = []) -> [UInt8] {
        var b: [UInt8] = [0xaa, 3, UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8)]
        b += [crc8(b), 0x0d, 0, 0, 0, 0, 0, 0, 0x21, 0x35, 1, 1, 0x35, command]
        b += payload
        let crc = crc16(b)
        return b + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
    }

    /// Requests one RuntimePropertyUpload from the authenticated mobile address.
    /// ConfigWrite field 72 triggers a read; it does not change upload intervals or
    /// device settings. The schema permits only one command field per request.
    static func runtimeUploadRequest() -> [UInt8] {
        let payload: [UInt8] = [0xc0, 0x04, 0x01]
        var bytes: [UInt8] = [0xaa, 0x13, UInt8(payload.count), 0]
        bytes += [crc8(bytes), 0x0d, 0, 0, 0, 0, 0, 0, 0x21, 0x02, 1, 1, 0xfe, 0x11]
        bytes += payload
        // Outgoing V19 requests use CRC16, even though incoming V19 uploads can
        // use a BB BB sentinel. Source 0x21 is required for local replies.
        let checksum = crc16(bytes)
        return bytes + [UInt8(truncatingIfNeeded: checksum), UInt8(checksum >> 8)]
    }
    static func parsePacket(_ bytes: [UInt8]) throws -> Packet {
        guard bytes.count >= 20, bytes[0] == 0xaa,
              bytes[1] & 0x0f == 3, crc8(Array(bytes.prefix(4))) == bytes[4] else {
            throw EcoFlowWirelessError.invalidPacket
        }
        let length = Int(bytes[2]) | Int(bytes[3]) << 8
        let sentinel = bytes[1] & 0x10 != 0
        guard length <= 10_000, bytes.count >= 18 + length + (sentinel ? 0 : 2) else {
            throw EcoFlowWirelessError.invalidPacket
        }
        if !sentinel, crc16(Array(bytes.prefix(20 + length))) != 0 { throw EcoFlowWirelessError.invalidPacket }
        var payload = Array(bytes[18..<(18 + length)])
        if bytes[6] != 0 { payload = payload.map { $0 ^ bytes[6] } }
        if sentinel, payload.suffix(2) == [0xbb, 0xbb] {
            payload.removeLast(2)
        }
        return Packet(source: bytes[12], commandSet: bytes[16], command: bytes[17], payload: payload)
    }

    struct FrameBuffer {
        struct Frame { let command: Bool; let payload: [UInt8] }
        private var bytes: [UInt8] = []
        mutating func append(_ data: Data) throws -> [Frame] {
            bytes += data
            guard bytes.count <= 32_768 else { bytes = []; throw EcoFlowWirelessError.invalidPacket }
            var result: [Frame] = []
            while bytes.count >= 2 {
                guard bytes[0] == 0x5a && bytes[1] == 0x5a else { bytes.removeFirst(); continue }
                guard bytes.count >= 6 else { break }
                let length = Int(bytes[4]) | Int(bytes[5]) << 8
                guard length >= 2, length <= 10_000 else { bytes.removeFirst(2); continue }
                if bytes.count < 6 + length {
                    // A corrupt prefix must not hold a subsequent complete,
                    // CRC-valid frame hostage until the receive buffer overflows.
                    var recovered = false
                    if bytes.count >= 10 {
                        for offset in 2...(bytes.count - 8) where bytes[offset] == 0x5a && bytes[offset + 1] == 0x5a {
                            let candidateLength = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                            if candidateLength >= 2, candidateLength <= 10_000,
                               offset + 6 + candidateLength <= bytes.count,
                               crc16(Array(bytes[offset..<(offset + 6 + candidateLength)])) == 0 {
                                bytes.removeFirst(offset); recovered = true; break
                            }
                        }
                    }
                    if recovered { continue }
                    break
                }
                let frame = Array(bytes.prefix(6 + length))
                guard crc16(frame) == 0 else { bytes.removeFirst(2); continue }
                result.append(Frame(command: frame[2] >> 4 == 0, payload: Array(frame[6..<(frame.count - 2)])))
                bytes.removeFirst(6 + length)
            }
            return result
        }
    }

    static func md5(_ data: [UInt8]) -> [UInt8] {
        // Required for compatibility with EcoFlow's existing protocol only.
        Array(Insecure.MD5.hash(data: Data(data)))
    }
    static func crypt(_ data: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard key.count == 16, iv.count == 16, encrypt || (!data.isEmpty && data.count % 16 == 0) else {
            throw EcoFlowWirelessError.invalidPacket
        }
        var output = [UInt8](repeating: 0, count: data.count + 16)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in data.withUnsafeBytes { input in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(encrypt ? kCCOptionPKCS7Padding : 0), keyBytes.baseAddress, 16,
                    ivBytes.baseAddress, input.baseAddress, data.count, &output, output.count, &written)
        } } }
        guard status == kCCSuccess else { throw EcoFlowWirelessError.invalidPacket }
        output = Array(output.prefix(written))
        if !encrypt, let padding = output.last, padding > 0, padding <= 16,
           output.count >= Int(padding), output.suffix(Int(padding)).allSatisfy({ $0 == padding }) {
            output.removeLast(Int(padding))
        }
        return output
    }

    struct KeyExchange {
        var publicKey = [UInt8](repeating: 0, count: 40)
        private var privateKey = [UInt8](repeating: 0, count: 21)
        init() throws {
            guard makeEcoFlowKey(&publicKey, &privateKey) == 1 else { throw EcoFlowWirelessError.authentication }
        }
        func sharedSecret(peer: [UInt8]) throws -> [UInt8] {
            guard peer.count == 40 else { throw EcoFlowWirelessError.authentication }
            var secret = [UInt8](repeating: 0, count: 20)
            guard makeEcoFlowSecret(peer, privateKey, &secret) == 1 else { throw EcoFlowWirelessError.authentication }
            return secret
        }
    }
    static func sessionKey(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 18 else { throw EcoFlowWirelessError.invalidPacket }
        let position = Int(data[16]) * 16 + Int(data[17] &- 1) * 256
        guard position + 16 <= EcoFlowSessionKeyData.bytes.count else { throw EcoFlowWirelessError.invalidPacket }
        return md5(Array(EcoFlowSessionKeyData.bytes[position..<(position + 16)]) + Array(data.prefix(16)))
    }

    struct Metrics {
        var battery: Double?
        var acWatts: Double?
        var totalWatts: Double?
        var acConnected: Bool?
        var acInputVoltage: Double?
        var changed: Bool { battery != nil || acWatts != nil || totalWatts != nil || acConnected != nil || acInputVoltage != nil }
    }

    /// DisplayPropertyUpload schema from upstream pd335_sys.proto. Missing fields
    /// remain unknown: protobuf updates are incremental, so never default to zero.
    static func metrics(_ data: [UInt8]) throws -> Metrics {
        try parseMetrics(data, runtime: false)
    }

    /// RuntimePropertyUpload has a separate schema. Only its explicitly present
    /// AC-input voltage is accepted; AC-output voltage and display fields cannot
    /// identify mains presence here.
    static func runtimeMetrics(_ data: [UInt8]) throws -> Metrics {
        try parseMetrics(data, runtime: true)
    }

    private static func parseMetrics(_ data: [UInt8], runtime: Bool) throws -> Metrics {
        var cursor = 0, result = Metrics()
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < data.count else { throw EcoFlowWirelessError.invalidPacket }
                let b = data[cursor]; cursor += 1
                guard index < 9 || b <= 1 else { throw EcoFlowWirelessError.invalidPacket }
                value |= UInt64(b & 0x7f) << (index * 7)
                if b & 0x80 == 0 { return value }
            }
            throw EcoFlowWirelessError.invalidPacket
        }
        while cursor < data.count {
            let tag = try varint(), field = tag >> 3, wire = tag & 7
            guard field > 0 else { throw EcoFlowWirelessError.invalidPacket }
            switch wire {
            case 0:
                let value = try varint()
                if !runtime, field == 202, value <= 1 { result.acConnected = value == 1 }
            case 1:
                guard cursor + 8 <= data.count else { throw EcoFlowWirelessError.invalidPacket }
                cursor += 8
            case 2:
                let length = try varint()
                guard length <= UInt64(data.count - cursor) else { throw EcoFlowWirelessError.invalidPacket }
                cursor += Int(length)
            case 5:
                guard cursor + 4 <= data.count else { throw EcoFlowWirelessError.invalidPacket }
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[cursor + $1]) << ($1 * 8) }
                cursor += 4
                let value = Double(Float(bitPattern: bits))
                guard value.isFinite else { continue }
                if runtime {
                    if field == 68, (0...300).contains(value) { result.acInputVoltage = value }
                    continue
                }
                if field == 262, (0...100).contains(value) { result.battery = value }
                if field == 242, result.battery == nil, (0...100).contains(value) { result.battery = value }
                if field == 54, (0...100_000).contains(value) { result.acWatts = value }
                if field == 3, (0...100_000).contains(value) { result.totalWatts = value }
            default: throw EcoFlowWirelessError.invalidPacket
            }
        }
        return result
    }
}
