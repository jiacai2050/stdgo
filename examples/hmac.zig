//! Example demonstrating stdgo's crypto.hmac (RFC 2104):
//! 1. HMAC-SHA256 message signing and authentication
//! 2. HMAC-MD5 message signing
//! 3. Cryptographic signature comparison

const std = @import("std");
const stdgo = @import("stdgo");
const hmac = stdgo.crypto.hmac;

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("=== stdgo: crypto.hmac Authentication Example ===\n\n", .{});

    const secret_key = "super-secret-api-key";
    const payload = "GET /v1/account?id=42&timestamp=1700000000";

    // 1. Compute HMAC-SHA256
    var mac_sha256: [32]u8 = undefined;
    hmac.sha256(secret_key, payload, &mac_sha256);
    const hex_sha256 = std.fmt.bytesToHex(mac_sha256, .lower);

    std.debug.print("1. HMAC-SHA256 Signature:\n", .{});
    std.debug.print("   Payload:   '{s}'\n", .{payload});
    std.debug.print("   Signature: {s}\n\n", .{hex_sha256});

    // 2. Compute HMAC-MD5
    var mac_md5: [16]u8 = undefined;
    hmac.md5(secret_key, payload, &mac_md5);
    const hex_md5 = std.fmt.bytesToHex(mac_md5, .lower);

    std.debug.print("2. HMAC-MD5 Signature:\n", .{});
    std.debug.print("   Signature: {s}\n\n", .{hex_md5});

    // 3. Signature Verification
    var verify_mac: [32]u8 = undefined;
    hmac.sha256(secret_key, payload, &verify_mac);

    const is_valid = std.mem.eql(u8, &mac_sha256, &verify_mac);
    std.debug.print("3. Signature Verification: {s}\n", .{if (is_valid) "VALID" else "INVALID"});

    // Tampered payload verification
    var tampered_mac: [32]u8 = undefined;
    hmac.sha256(secret_key, "GET /v1/account?id=99", &tampered_mac);
    const is_tampered_valid = std.mem.eql(u8, &mac_sha256, &tampered_mac);
    std.debug.print("   Tampered Payload Verification: {s} (Expected: REJECTED)\n\n", .{if (is_tampered_valid) "VALID" else "REJECTED"});

    std.debug.print("=== HMAC demo completed successfully! ===\n", .{});
}
