import Foundation

enum DirectoryParser {
    static func parse(_ data: Data, machineReadable: Bool, preferredEncoding: FTPTextEncoding? = nil) throws -> DirectoryListing {
        guard data.count <= TransferPlan.maximumListingBytes else { throw FTPError.incompatibleListing }
        let encoding = try preferredEncoding ?? FTPTextEncoding.detect(data)
        let text = try encoding.decode(data)
        var entries: [RemoteEntry] = []
        var names = Set<Data>()
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if !machineReadable && line.range(of: "^total [0-9]+$", options: .regularExpression) != nil { continue }
            let entry = try machineReadable ? mlsd(line, encoding: encoding) : legacy(line, encoding: encoding)
            guard let entry else { continue }
            guard names.insert(entry.rawName).inserted else { throw FTPError.incompatibleListing }
            entries.append(entry)
        }
        return DirectoryListing(entries: entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, encoding: encoding)
    }

    private static func mlsd(_ line: String, encoding: FTPTextEncoding) throws -> RemoteEntry? {
        guard let separator = line.firstIndex(of: " ") else { throw FTPError.incompatibleListing }
        let factsText = line[..<separator]
        let name = String(line[line.index(after: separator)...])
        var facts: [String: String] = [:]
        for fact in factsText.split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw FTPError.incompatibleListing }
            facts[String(parts[0]).lowercased()] = String(parts[1])
        }
        let type = facts["type"]?.lowercased()
        if type == "cdir" || type == "pdir" { return nil }
        let kind: RemoteEntry.Kind
        switch type {
        case "dir": kind = .directory
        case "file": kind = .regularFile
        case "os.unix=slink", "os.unix=symlink": kind = .symbolicLink
        case let value? where value.hasPrefix("os.unix=slink:"): kind = .symbolicLink
        case "os.unix=chr", "os.unix=blk", "os.unix=fifo", "os.unix=socket": kind = .other
        default: kind = .unknown
        }
        return try makeEntry(name, kind: kind, size: facts["size"].flatMap(Int64.init), encoding: encoding)
    }

    private static func legacy(_ line: String, encoding: FTPTextEncoding) throws -> RemoteEntry? {
        if let groups = captures(line, pattern: "^([dlbcps-])[rwxstST-]{9}[+@.]?\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+(?:,\\s*\\d+)?)\\s+\\S+\\s+\\d{1,2}\\s+(?:\\d{1,2}:\\d{2}|\\d{4})\\s(.+)$") {
            let kind: RemoteEntry.Kind
            switch groups[0] {
            case "d": kind = .directory
            case "-": kind = .regularFile
            case "l": kind = .symbolicLink
            default: kind = .other
            }
            var name = groups[2]
            if kind == .symbolicLink {
                guard let separator = name.range(of: " -> ", options: .backwards) else { throw FTPError.incompatibleListing }
                name = String(name[..<separator.lowerBound])
            }
            return try makeEntry(name, kind: kind, size: Int64(groups[1]), encoding: encoding)
        }
        if let groups = captures(line, pattern: "^\\d{2}-\\d{2}-\\d{2,4}\\s+\\d{1,2}:\\d{2}(?:AM|PM)\\s+(<DIR>|\\d+)\\s+(.+)$", options: .caseInsensitive) {
            return try makeEntry(groups[1], kind: groups[0].uppercased() == "<DIR>" ? .directory : .regularFile, size: Int64(groups[0]), encoding: encoding)
        }
        throw FTPError.incompatibleListing
    }

    private static func captures(_ text: String, pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }

    private static func makeEntry(_ name: String, kind: RemoteEntry.Kind, size: Int64?, encoding: FTPTextEncoding) throws -> RemoteEntry? {
        if name == "." || name == ".." { return nil }
        let bytes = try encoding.encode(name)
        try RemotePath.validateName(bytes)
        guard size == nil || size! >= 0 else { throw FTPError.incompatibleListing }
        return RemoteEntry(name: name, rawName: bytes, kind: kind, size: size)
    }
}
