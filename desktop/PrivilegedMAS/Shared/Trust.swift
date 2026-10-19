import Foundation
import Security
import CryptoKit
import Darwin

enum Failure: Error { case refused }

func require(_ condition: Bool) throws { if !condition { throw Failure.refused } }

func checkCode(_ path: String) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
    try require(SecRequirementCreateWithString(Contract.requirement("org.macseed.development.bundled-mas") as CFString, [], &requirement) == errSecSuccess)
    try require(SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    try require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == Contract.digest)
}

func requireNoACL(_ fd: Int32) throws {
    errno = 0
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { try require(errno == ENOENT); return }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    try require(acl_valid(acl) == 0)
    var entry: acl_entry_t?
    errno = 0
    let status = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    try require(status == -1 && errno == EINVAL)
}
