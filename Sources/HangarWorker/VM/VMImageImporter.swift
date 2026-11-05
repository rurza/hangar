import Compression
import CryptoKit
import Foundation
import HangarCore
import Synchronization

/// `registry/repository[:tag]@sha256:digest`.
public struct OCIReference: Sendable, Equatable, CustomStringConvertible {
    public var registry: String
    public var repository: String
    public var tag: String?
    public var digest: String?

    public init?(_ text: String) {
        var rest = Substring(text)
        if let at = rest.firstIndex(of: "@") {
            let digest = String(rest[rest.index(after: at)...])
            guard digest.hasPrefix("sha256:"), digest.count == 71 else { return nil }
            self.digest = digest
            rest = rest[..<at]
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        registry = String(rest[..<slash])
        var path = rest[rest.index(after: slash)...]
        if let colon = path.lastIndex(of: ":") {
            tag = String(path[path.index(after: colon)...])
            path = path[..<colon]
        }
        repository = String(path)
        guard !registry.isEmpty, !repository.isEmpty, registry.contains("."), tag != nil || digest != nil else { return nil }
    }

    public var description: String {
        registry + "/" + repository + (tag.map { ":" + $0 } ?? "") + (digest.map { "@" + $0 } ?? "")
    }
}

/// A Tart OCI manifest (`application/vnd.oci.image.manifest.v1+json`).
struct OCIManifest: Decodable {
    struct Layer: Decodable {
        var mediaType: String
        var digest: String
        var size: Int64
        var annotations: [String: String]?
    }

    var layers: [Layer]
    var annotations: [String: String]?

    static let configType = "application/vnd.cirruslabs.tart.config.v1"
    static let diskType = "application/vnd.cirruslabs.tart.disk.v2"
    static let nvramType = "application/vnd.cirruslabs.tart.nvram.v1"
    static let uncompressedSize = "org.cirruslabs.tart.uncompressed-size"
    static let uncompressedDigest = "org.cirruslabs.tart.uncompressed-content-digest"
    static let diskSize = "org.cirruslabs.tart.uncompressed-disk-size"
}

public enum VMImportError: Error, Equatable, CustomStringConvertible {
    case notPinned(String)
    case registry(String)
    case digestMismatch(what: String)
    case notTartImage(String)
    case lowDisk(freeGB: Int, neededGB: Int)
    case exists(String)

    public var description: String {
        switch self {
        case .notPinned(let reference): "\(reference) is not pinned: add @sha256:<digest>"
        case .registry(let detail): "the registry answered: \(detail)"
        case .digestMismatch(let what): "\(what) does not match its digest; the download is corrupt or was changed"
        case .notTartImage(let detail): "not a Tart macOS image: \(detail)"
        case .lowDisk(let free, let needed):
            "stopped: only \(free) GB free on the VM storage volume, and the import keeps \(needed) GB free"
        case .exists(let name): "there is already an image named \(name); remove it first (`hangar-worker vm image remove \(name)`)"
        }
    }
}

/// Pulls a Tart-format macOS image from an OCI registry into `images/<name>` (VM builds design, *Base image pipeline*,
/// first slice): the config, the NVRAM, and the disk as LZ4 chunks decompressed straight into a sparse `disk.img`
/// (all-zero blocks become holes). Every blob is checked against its digest, the manifest against the pinned one.
/// It is assembled in `images/.partial-<name>` and renamed when complete; a failed or stopped import deletes it.
/// It stops when free space on the volume would fall below `floorGB`.
public struct VMImageImporter: Sendable {
    /// Cirrus Labs' vanilla macOS 26.6.2 (Tart format), the one the spike measured: macOS with Setup Assistant done,
    /// user `admin`/`admin`, SSH on, passwordless sudo.
    public static let defaultVanilla =
        "ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640"

    public var session: URLSession
    public var parallelLayers = 4
    public var floorGB: Int
    public var progress: @Sendable (String) -> Void

    public init(session: URLSession = .shared, floorGB: Int, progress: @escaping @Sendable (String) -> Void) {
        self.session = session
        self.floorGB = floorGB
        self.progress = progress
    }

    public func importImage(_ reference: OCIReference, as name: String, into storage: VMStorage, now: Date = Date()) async throws {
        guard let digest = reference.digest else { throw VMImportError.notPinned(reference.description) }
        guard !FileManager.default.fileExists(atPath: storage.image(name).path) else { throw VMImportError.exists(name) }
        try storage.create()
        let partial = storage.partialImage(name)
        try? FileManager.default.removeItem(atPath: partial.path)
        try FileManager.default.createDirectory(atPath: partial.path, withIntermediateDirectories: true)
        do {
            try await pull(reference, digest: digest, into: partial, storage: storage, now: now)
            try FileManager.default.moveItem(atPath: partial.path, toPath: storage.image(name).path)
        } catch {
            try? FileManager.default.removeItem(atPath: partial.path)
            throw error
        }
    }

    private func pull(
        _ reference: OCIReference, digest: String, into image: VMImageDirectory, storage: VMStorage, now: Date
    ) async throws {
        let registry = Registry(reference: reference, session: session)
        let manifestData = try await registry.get(
            "manifests/\(digest)", accept: "application/vnd.oci.image.manifest.v1+json")
        guard "sha256:" + SHA256File.hex(of: manifestData) == digest else { throw VMImportError.digestMismatch(what: "the manifest") }
        let manifest: OCIManifest
        do { manifest = try JSONDecoder().decode(OCIManifest.self, from: manifestData) } catch {
            throw VMImportError.notTartImage("the manifest is unreadable")
        }
        guard let configLayer = manifest.layers.first(where: { $0.mediaType == OCIManifest.configType }),
            let nvramLayer = manifest.layers.first(where: { $0.mediaType == OCIManifest.nvramType })
        else { throw VMImportError.notTartImage("no Tart config or NVRAM layer") }
        let disks = manifest.layers.filter { $0.mediaType == OCIManifest.diskType }
        guard !disks.isEmpty else { throw VMImportError.notTartImage("no disk layers (only Tart's disk v2 format imports)") }

        // The disk's blocks on this volume are about the compressed size: Tart skips zeros as this does.
        let compressed = disks.reduce(Int64(0)) { $0 + $1.size }
        let free = VMVolume.freeGB(at: storage.root)
        let needed = Double(floorGB) + Double(compressed) * 1.15 / 1_000_000_000
        guard free >= needed else { throw VMImportError.lowDisk(freeGB: Int(free), neededGB: Int(needed.rounded(.up))) }
        progress("importing \(reference) (\(Self.gigabytes(compressed)) GB to download, \(disks.count) disk chunks)")

        let config = try await registry.blob(configLayer.digest)
        guard "sha256:" + SHA256File.hex(of: config) == configLayer.digest else {
            throw VMImportError.digestMismatch(what: "the config")
        }
        guard let tart = try? JSONCoding.decoder.decode(TartConfig.self, from: config), tart.os == "darwin", tart.arch == "arm64"
        else { throw VMImportError.notTartImage("the config is not an arm64 macOS VM's") }
        try config.write(to: URL(fileURLWithPath: image.config))
        let nvram = try await registry.blob(nvramLayer.digest)
        guard "sha256:" + SHA256File.hex(of: nvram) == nvramLayer.digest else { throw VMImportError.digestMismatch(what: "the NVRAM") }
        try nvram.write(to: URL(fileURLWithPath: image.nvram))

        var offsets: [Int64] = []
        var total: Int64 = 0
        for layer in disks {
            guard let size = layer.annotations?[OCIManifest.uncompressedSize].flatMap(Int64.init) else {
                throw VMImportError.notTartImage("a disk chunk has no uncompressed size")
            }
            offsets.append(total)
            total += size
        }
        if let declared = manifest.annotations?[OCIManifest.diskSize].flatMap(Int64.init) { total = max(total, declared) }
        guard FileManager.default.createFile(atPath: image.disk, contents: nil) else { throw VMStorageError.unreadable(image.disk) }
        let disk = open(image.disk, O_RDWR | O_CLOEXEC)
        guard disk >= 0 else { throw SecretsError.io(path: image.disk, errno: errno) }
        defer { close(disk) }
        guard ftruncate(disk, total) == 0 else { throw SecretsError.io(path: image.disk, errno: errno) }

        let counter = Mutex((done: 0, bytes: Int64(0)))
        let started = ContinuousClock.now
        let progress = self.progress
        let layerCount = disks.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in disks.indices {
                if index >= parallelLayers { try await group.next() }
                let layer = disks[index], offset = offsets[index]
                group.addTask { [self] in
                    try await diskLayer(layer, at: offset, into: disk, registry: registry, storage: storage)
                    let (done, bytes) = counter.withLock { state -> (Int, Int64) in
                        state.done += 1
                        state.bytes += layer.size
                        return (state.done, state.bytes)
                    }
                    let elapsed = max((ContinuousClock.now - started).components.seconds, 1)
                    progress("disk \(done)/\(layerCount) · \(Self.gigabytes(bytes)) of \(Self.gigabytes(compressed)) GB · \(bytes / elapsed / 1_000_000) MB/s")
                }
            }
            try await group.waitForAll()
        }
        guard fsync(disk) == 0 else { throw SecretsError.io(path: image.disk, errno: errno) }
        try VMBundleFile.write(
            VMImageMetadata(name: image.name, macOS: reference.tag ?? "", source: reference.description, createdAt: now),
            to: image.metadata)
        progress("imported in \(VMLauncher.seconds(since: started))")
    }

    /// One disk chunk: downloaded to a temporary file (one chunk at a time per task, so at most `parallelLayers`
    /// compressed chunks are on disk), checked, and decompressed into place. Retried twice.
    private func diskLayer(
        _ layer: OCIManifest.Layer, at offset: Int64, into disk: Int32, registry: Registry, storage: VMStorage
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let free = VMVolume.freeGB(at: storage.root)
                guard free >= Double(floorGB) else { throw VMImportError.lowDisk(freeGB: Int(free), neededGB: floorGB) }
                let file = try await registry.download(layer.digest)
                defer { try? FileManager.default.removeItem(at: file) }
                try Self.decompress(file: file, layer: layer, offset: offset, into: disk)
                return
            } catch let error as VMImportError {
                throw error
            } catch {
                if attempt >= 3 || Task.isCancelled { throw error }
            }
        }
    }

    /// Decompresses Apple LZ4 (what Tart writes) from `file` into `disk` at `offset`, skipping all-zero 64 KiB blocks,
    /// and checks the compressed and uncompressed digests.
    static func decompress(file: URL, layer: OCIManifest.Layer, offset: Int64, into disk: Int32) throws {
        var compressedHash = SHA256()
        var plainHash = SHA256()
        var position = offset
        var writeError: Int32?
        let filter = try OutputFilter(.decompress, using: .lz4, bufferCapacity: 1 << 20) { data in
            guard let data, writeError == nil else { return }
            plainHash.update(data: data)
            writeError = writeSkippingZeros(data, at: position, into: disk)
            position += Int64(data.count)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            compressedHash.update(data: chunk)
            try filter.write(chunk)
            if let writeError { throw SecretsError.io(path: "disk.img", errno: writeError) }
        }
        try filter.finalize()
        if let writeError { throw SecretsError.io(path: "disk.img", errno: writeError) }
        guard "sha256:" + hex(compressedHash.finalize()) == layer.digest else {
            throw VMImportError.digestMismatch(what: "disk chunk \(layer.digest.prefix(19))")
        }
        if let expected = layer.annotations?[OCIManifest.uncompressedDigest], "sha256:" + hex(plainHash.finalize()) != expected {
            throw VMImportError.digestMismatch(what: "disk chunk \(layer.digest.prefix(19)) (decompressed)")
        }
    }

    static let block = 64 * 1024

    /// Writes `data` at `offset`, leaving all-zero blocks as holes in the sparse file. Returns errno on failure.
    static func writeSkippingZeros(_ data: Data, at offset: Int64, into descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { buffer -> Int32? in
            var start = 0
            while start < buffer.count {
                let end = min(start + block, buffer.count)
                let slice = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                if !isZero(slice) {
                    var written = 0
                    while written < slice.count {
                        let result = pwrite(descriptor, slice.baseAddress! + written, slice.count - written, off_t(offset) + off_t(start + written))
                        if result < 0 {
                            if errno == EINTR { continue }
                            return errno
                        }
                        written += result
                    }
                }
                start = end
            }
            return nil
        }
    }

    static func isZero(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        while index + 8 <= bytes.count {
            if bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) != 0 { return false }
            index += 8
        }
        while index < bytes.count {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000_000) }
}

/// An OCI registry with anonymous bearer tokens (`WWW-Authenticate: Bearer realm=…,service=…,scope=…`).
final class Registry: Sendable {
    private let reference: OCIReference
    private let session: URLSession
    private let token = Mutex<String?>(nil)

    init(reference: OCIReference, session: URLSession) {
        self.reference = reference
        self.session = session
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://\(reference.registry)/v2/\(reference.repository)/\(path)")!
    }

    func get(_ path: String, accept: String? = nil) async throws -> Data {
        let (data, _) = try await send(path, accept: accept) { request in try await self.session.data(for: request) }
        return data
    }

    func blob(_ digest: String) async throws -> Data { try await get("blobs/\(digest)") }

    /// Downloads a blob to a temporary file (the session's own).
    func download(_ digest: String) async throws -> URL {
        let (url, _) = try await send("blobs/\(digest)", accept: nil) { request in try await self.session.download(for: request) }
        return url
    }

    private func send<Value>(
        _ path: String, accept: String?, _ perform: @Sendable (URLRequest) async throws -> (Value, URLResponse)
    ) async throws -> (Value, URLResponse) {
        for _ in 0..<2 {
            var request = URLRequest(url: url(path))
            request.timeoutInterval = 120
            if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
            if let token = token.withLock({ $0 }) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (value, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else { throw VMImportError.registry("no HTTP response") }
            if http.statusCode == 401, let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") {
                try await authenticate(challenge)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw VMImportError.registry("HTTP \(http.statusCode) for \(path)") }
            return (value, response)
        }
        throw VMImportError.registry("authentication failed for \(path)")
    }

    private func authenticate(_ challenge: String) async throws {
        let fields = Self.challengeFields(challenge)
        guard let realm = fields["realm"], var components = URLComponents(string: realm) else {
            throw VMImportError.registry("unsupported authentication: \(challenge)")
        }
        components.queryItems = ["service", "scope"].compactMap { key in fields[key].map { URLQueryItem(name: key, value: $0) } }
        guard let url = components.url else { throw VMImportError.registry("bad token realm \(realm)") }
        let (data, _) = try await session.data(from: url)
        struct TokenResponse: Decodable {
            var token: String?
            var access_token: String?
        }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let value = response.token ?? response.access_token else { throw VMImportError.registry("no token from \(realm)") }
        token.withLock { $0 = value }
    }

    /// `Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:x:pull"` → its fields.
    static func challengeFields(_ challenge: String) -> [String: String] {
        guard challenge.hasPrefix("Bearer ") else { return [:] }
        var fields: [String: String] = [:]
        let pattern = /([a-zA-Z]+)="([^"]*)"/
        for match in challenge.dropFirst("Bearer ".count).matches(of: pattern) {
            fields[String(match.output.1)] = String(match.output.2)
        }
        return fields
    }
}
