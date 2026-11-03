import Foundation

struct ProtobufReader {
    let data: Data
    private let errorMessage: String
    private(set) var offset = 0

    init(data: Data, errorMessage: String) {
        self.data = data
        self.errorMessage = errorMessage
    }

    mutating func nextField() throws -> (number: Int, wireType: UInt8)? {
        guard offset < data.count else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = UInt8(key & 0x07)
        guard number > 0 else { throw protobufError }
        return (number, wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw protobufError }
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw protobufError
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw protobufError }
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        offset += 8
        return value
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(Int.max) else { throw protobufError }
        let byteCount = Int(length)
        guard offset + byteCount <= data.count else { throw protobufError }
        defer { offset += byteCount }
        return data.subdata(in: offset..<(offset + byteCount))
    }

    mutating func skip(wireType: UInt8) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard offset + 8 <= data.count else { throw protobufError }
            offset += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard offset + 4 <= data.count else { throw protobufError }
            offset += 4
        default:
            throw protobufError
        }
    }

    private var protobufError: UsageClientError {
        .invalidResponse(errorMessage)
    }
}

enum ProtobufSupport {
    static func timestamp(from data: Data, errorMessage: String) throws -> Date? {
        var reader = ProtobufReader(data: data, errorMessage: errorMessage)
        var seconds: Int64?
        var nanoseconds: Int32 = 0
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 0):
                seconds = Int64(bitPattern: try reader.readVarint())
            case (2, 0):
                nanoseconds = Int32(truncatingIfNeeded: try reader.readVarint())
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
        guard let seconds else { return nil }
        return Date(
            timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000
        )
    }
}

enum CursorProtocolSupport {
    static func checksum(
        machineID: String,
        macMachineID: String? = nil,
        now: Date = Date()
    ) -> String {
        let timestamp = UInt64(floor(now.timeIntervalSince1970 / 1_000))
        let javascriptTimestamp = Int32(truncatingIfNeeded: timestamp)
        var bytes = [40, 32, 24, 16, 8, 0].map { shift in
            UInt8(truncatingIfNeeded: javascriptTimestamp >> (shift & 31))
        }
        var previous: UInt8 = 165
        for index in bytes.indices {
            bytes[index] = (bytes[index] ^ previous) &+ UInt8(index)
            previous = bytes[index]
        }

        let machinePart = macMachineID.map { "\(machineID)/\($0)" } ?? machineID
        return Data(bytes).base64URLEncodedString() + machinePart
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
