import Foundation

/// How much disk a set of files really takes. `du` adds up each file's allocated blocks, so APFS clones (a VM image,
/// its slots and job clones share most of their blocks) count many times over: on a VM Mac it reads 136 GB where
/// 51 GB are in use. Here every file's physical extents are collected and merged, so a block shared by any number of
/// clones counts once. A block a Time Machine local snapshot also holds counts too: it is Hangar's, though deleting
/// the file frees it only once the snapshot goes.
public enum DiskUsage {
    /// The bytes the regular files under `paths` (files or directories, walked without following symbolic links)
    /// occupy, each physical block once. A file whose extents cannot be read (another file system, no permission)
    /// counts its allocated size.
    public static func bytes(of paths: [String]) -> UInt64 {
        var collector = ExtentCollector()
        for path in paths { collector.add(tree: path) }
        return collector.total
    }

    public static func bytes(of path: String) -> UInt64 { bytes(of: [path]) }

    /// What each group of paths adds, in order: a block an earlier group already holds is not counted again, so a
    /// slot's state counts only what it does not share with its image, and the results add up to the whole.
    public static func bytes(ofGroups groups: [[String]]) -> [UInt64] {
        var collector = ExtentCollector()
        var counted: UInt64 = 0
        return groups.map { group in
            for path in group { collector.add(tree: path) }
            let total = collector.total
            defer { counted = total }
            return total > counted ? total - counted : 0
        }
    }

    /// Decimal gigabytes, as Finder and `df -H` count them.
    public static func gigabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_000_000_000 }

    /// "1.3 GB", "120 MB", "0 MB".
    public static func text(_ bytes: UInt64) -> String {
        let gigabytes = gigabytes(bytes)
        if gigabytes >= 10 { return String(format: "%.0f GB", gigabytes) }
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

/// Physical extents per device, merged at the end.
private struct ExtentCollector {
    static let blockSize: UInt64 = 4096

    private var extents: [dev_t: [(start: UInt64, end: UInt64)]] = [:]
    /// Files whose extents could not be read, at their allocated size.
    private var unmapped: UInt64 = 0

    mutating func add(tree path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            add(file: path, info: info)
        case S_IFDIR:
            guard let enumerator = FileManager.default.enumerator(atPath: path) else { return }
            while let relative = enumerator.nextObject() as? String {
                let child = path + "/" + relative
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0, childInfo.st_mode & S_IFMT == S_IFREG else { continue }
                add(file: child, info: childInfo)
            }
        default:
            return
        }
    }

    private mutating func add(file path: String, info: stat) {
        let allocated = UInt64(max(info.st_blocks, 0)) * 512
        guard allocated > 0 else { return }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            unmapped += allocated
            return
        }
        defer { close(descriptor) }
        var found: [(start: UInt64, end: UInt64)] = []
        let size = Int64(info.st_size)
        var offset: Int64 = 0
        while offset < size {
            // Holes have no blocks: jump to the next data. ENXIO means there is none after `offset`.
            let data = lseek(descriptor, offset, SEEK_DATA)
            if data < 0 { break }
            offset = data
            var mapping = log2phys()
            mapping.l2p_contigbytes = size - offset
            mapping.l2p_devoffset = offset
            guard fcntl(descriptor, F_LOG2PHYS_EXT, &mapping) == 0, mapping.l2p_contigbytes > 0, mapping.l2p_devoffset >= 0
            else {
                // A compressed file or a file system without the call: its allocation is the best there is.
                unmapped += allocated
                return
            }
            let start = UInt64(mapping.l2p_devoffset)
            let length = UInt64(mapping.l2p_contigbytes)
            let rounded = (length + Self.blockSize - 1) / Self.blockSize * Self.blockSize
            found.append((start, start + rounded))
            offset += mapping.l2p_contigbytes
        }
        extents[info.st_dev, default: []].append(contentsOf: found)
    }

    var total: UInt64 {
        var sum = unmapped
        for ranges in extents.values {
            var current: (start: UInt64, end: UInt64)?
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                if let open = current, range.start <= open.end {
                    current = (open.start, max(open.end, range.end))
                } else {
                    if let open = current { sum += open.end - open.start }
                    current = range
                }
            }
            if let open = current { sum += open.end - open.start }
        }
        return sum
    }
}
