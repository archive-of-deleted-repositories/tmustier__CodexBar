import Foundation

extension CostUsageScanner {
    enum PiUsageTarget: Sendable {
        case codex
        case claude
    }

    struct PiParseResult: Sendable {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
    }

    static func scanPiSessionFiles(
        target: PiUsageTarget,
        range: CostUsageDayRange,
        options: Options,
        cache: inout CostUsageCache) -> Set<String>
    {
        guard let root = defaultPiSessionsRoot(options: options) else { return [] }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let files = Self.listPiSessionFiles(root: root)
        var touched: Set<String> = []

        for fileURL in files {
            let path = fileURL.path
            touched.insert(path)

            self.processPiFile(
                url: fileURL,
                range: range,
                target: target,
                cache: &cache)
        }

        return touched
    }

    private static func defaultPiSessionsRoot(options: Options) -> URL? {
        if let override = options.piSessionsRoot { return override }
        let env = ProcessInfo.processInfo
            .environment["PI_CODING_AGENT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base: URL
        if let env, !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            base = home
                .appendingPathComponent(".pi", isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
        }
        if base.lastPathComponent == "sessions" {
            return base
        }
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    private static func listPiSessionFiles(root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            out.append(url)
        }
        return out
    }

    private static func processPiFile(
        url: URL,
        range: CostUsageDayRange,
        target: PiUsageTarget,
        cache: inout CostUsageCache)
    {
        let path = url.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 { return }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeMs = Int64(mtime * 1000)

        if let cached = cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size
        {
            return
        }

        if let cached = cache.files[path] {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
            if canIncremental {
                let delta = Self.parsePiFile(
                    fileURL: url,
                    range: range,
                    target: target,
                    startOffset: startOffset)
                if !delta.days.isEmpty {
                    Self.applyFileDays(cache: &cache, fileDays: delta.days, sign: 1)
                }

                var mergedDays = cached.days
                Self.mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = Self.makeFileUsage(
                    mtimeUnixMs: mtimeMs,
                    size: size,
                    days: mergedDays,
                    parsedBytes: delta.parsedBytes)
                return
            }

            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }

        let parsed = Self.parsePiFile(fileURL: url, range: range, target: target)
        let usage = Self.makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: parsed.days,
            parsedBytes: parsed.parsedBytes)
        cache.files[path] = usage
        Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
    }

    private static func parsePiFile(
        fileURL: URL,
        range: CostUsageDayRange,
        target: PiUsageTarget,
        startOffset: Int64 = 0) -> PiParseResult
    {
        var days: [String: [String: [Int]]] = [:]
        var seenKeys: Set<String> = []

        struct PiTokens: Sendable {
            let input: Int
            let cacheRead: Int
            let cacheCreate: Int
            let output: Int
        }

        func addCodex(dayKey: String, model: String, tokens: PiTokens) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + min(tokens.cacheRead, tokens.input)
            packed[2] = (packed[safe: 2] ?? 0) + tokens.output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func addClaude(dayKey: String, model: String, tokens: PiTokens) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeClaudeModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + tokens.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + tokens.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + tokens.output
            if let cost = CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                outputTokens: tokens.output)
            {
                let costScale = 1_000_000_000.0
                let costNanos = Int((cost * costScale).rounded())
                packed[4] = (packed[safe: 4] ?? 0) + costNanos
            }
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 512 * 1024
        let prefixBytes = maxLineBytes

        let parsedBytes = (try? CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: startOffset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            onLine: { line in
                guard !line.bytes.isEmpty else { return }
                guard !line.wasTruncated else { return }
                guard line.bytes.containsAscii(#""type":"message""#) else { return }
                guard line.bytes.containsAscii(#""usage""#) else { return }
                guard line.bytes.containsAscii(#""provider""#)
                    || line.bytes.containsAscii(#""api""#)
                else { return }

                guard
                    let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                    let type = obj["type"] as? String,
                    type == "message",
                    let message = obj["message"] as? [String: Any]
                else { return }

                guard (message["role"] as? String) == "assistant" else { return }

                let provider = (message["provider"] as? String) ?? (obj["provider"] as? String)
                let api = message["api"] as? String
                guard Self.piMatchesTarget(target, provider: provider, api: api) else { return }

                let tsText = (obj["timestamp"] as? String) ?? (message["timestamp"] as? String)
                guard let tsText else { return }
                guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

                let messageId = (message["id"] as? String) ?? (obj["id"] as? String)
                let requestId = (obj["requestId"] as? String) ?? (message["requestId"] as? String)
                if let messageId, let requestId {
                    let key = "\(messageId):\(requestId)"
                    if seenKeys.contains(key) { return }
                    seenKeys.insert(key)
                } else if let messageId {
                    if seenKeys.contains(messageId) { return }
                    seenKeys.insert(messageId)
                }

                guard let usage = message["usage"] as? [String: Any] else { return }

                let input = self.intValue(usage, keys: ["input", "input_tokens"])
                let output = self.intValue(usage, keys: ["output", "output_tokens"])
                let cacheRead = self.intValue(
                    usage,
                    keys: ["cacheRead", "cache_read", "cache_read_input_tokens"])
                let cacheCreate = self.intValue(
                    usage,
                    keys: ["cacheWrite", "cache_write", "cache_creation_input_tokens"])
                let tokens = PiTokens(
                    input: max(0, input),
                    cacheRead: max(0, cacheRead),
                    cacheCreate: max(0, cacheCreate),
                    output: max(0, output))
                if tokens.input == 0, tokens.cacheRead == 0, tokens.cacheCreate == 0, tokens.output == 0 { return }

                guard let model = (message["model"] as? String) ?? (message["modelId"] as? String) else { return }

                switch target {
                case .codex:
                    addCodex(dayKey: dayKey, model: model, tokens: tokens)
                case .claude:
                    addClaude(dayKey: dayKey, model: model, tokens: tokens)
                }
            })) ?? startOffset

        return PiParseResult(days: days, parsedBytes: parsedBytes)
    }

    private static func intValue(_ dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] {
                if let number = value as? NSNumber { return number.intValue }
                if let text = value as? String, let parsed = Int(text) { return parsed }
            }
        }
        return 0
    }

    private static func piMatchesTarget(_ target: PiUsageTarget, provider: String?, api: String?) -> Bool {
        let providerText = provider?.lowercased() ?? ""
        let apiText = api?.lowercased() ?? ""
        switch target {
        case .codex:
            return providerText.contains("openai-codex") || apiText.contains("openai-codex")
        case .claude:
            return providerText.contains("anthropic") || apiText.contains("anthropic")
        }
    }
}
