// Build-time encoder only. Never bundled or launched by Python Core.
import Foundation
import LightweightCodeRequirements

let values = CommandLine.arguments.dropFirst()
guard !values.isEmpty, values.count <= 8,
      values.allSatisfy({ $0.count == 40 && $0.allSatisfy { $0.isHexDigit && $0.isASCII } }) else {
    exit(2)
}
let hashes = values.map { value -> Data in
    let bytes = Array(value.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map {
        UInt8(String(bytes: bytes[$0..<$0+2], encoding: .utf8)!, radix: 16)!
    })
}
let task = Process()
task.launchRequirement = try LaunchCodeRequirement.allOf { CodeDirectoryHash.in(hashes) }
guard let data = task.launchRequirementData, !data.isEmpty, data.count <= 4096 else { exit(2) }
print(data.base64EncodedString())
