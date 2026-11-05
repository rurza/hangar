import Foundation

/// A NAT guest's address. The host's bootpd writes each lease to `/var/db/dhcpd_leases` (readable by every user):
///
/// ```
/// {
///     name=admins-Virtual-Machine
///     ip_address=192.168.64.2
///     hw_address=1,2:68:67:a:0:0
///     identifier=1,2:68:67:a:0:0
///     lease=0x690b9abc
/// }
/// ```
public enum DHCPLeases {
    public static let path = "/var/db/dhcpd_leases"

    /// The address leased to `mac` most recently (the latest `lease` expiry wins), or nil.
    public static func address(for mac: String, in text: String) -> String? {
        let wanted = "1," + VMMACAddress.leaseForm(mac)
        var best: (ip: String, expiry: UInt64)?
        for block in text.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                fields[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
            }
            guard fields["hw_address"] == wanted, let ip = fields["ip_address"] else { continue }
            let expiry = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
            if best == nil || expiry >= best!.expiry { best = (ip, expiry) }
        }
        return best?.ip
    }

    public static func address(for mac: String, leasesFile: String = DHCPLeases.path) -> String? {
        guard let text = try? String(contentsOfFile: leasesFile, encoding: .utf8) else { return nil }
        return address(for: mac, in: text)
    }
}
