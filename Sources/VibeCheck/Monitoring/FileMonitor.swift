import Foundation

/// Monitors a directory for JSONL file changes using DispatchSource
/// Detects file modifications and triggers processing
actor FileMonitor {
    private let watchDirectory: URL
    private let parser: JSONLParser
    private var fileDescriptor: Int32?
    private var source: DispatchSourceFileSystemObject?
    private var isMonitoring = false
    private var lastModificationTimes: [String: Date] = [:]

    init(watchDirectory: URL, parser: JSONLParser) {
        self.watchDirectory = watchDirectory
        self.parser = parser
    }

    /// Start monitoring the directory for file changes
    func startMonitoring() async throws {
        guard !isMonitoring else {
            print("⚠️  Already monitoring")
            return
        }

        // Ensure directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: watchDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FileMonitorError.directoryNotFound(watchDirectory.path)
        }

        print("👀 Starting file monitor on: \(watchDirectory.path)")

        // Open directory for monitoring
        let fd = open(watchDirectory.path, O_EVTONLY)
        guard fd >= 0 else {
            throw FileMonitorError.cannotOpenDirectory(watchDirectory.path)
        }

        self.fileDescriptor = fd

        // Create dispatch source
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        // Capture self as weak to avoid retain cycle
        source.setEventHandler { [weak parser, weak self] in
            Task {
                guard let parser = parser, let self = self else { return }
                await self.handleDirectoryChange(parser: parser)
            }
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        source.resume()
        self.source = source
        self.isMonitoring = true

        // Add polling backup (every 2 seconds) for reliability
        await startPollingBackup()

        print("✅ File monitor started")
    }

    /// Stop monitoring
    func stopMonitoring() async {
        guard isMonitoring else { return }

        print("🛑 Stopping file monitor")

        // Stop polling
        await stopPollingBackup()

        // Cancel dispatch source
        source?.cancel()
        source = nil

        // Close file descriptor
        if let fd = fileDescriptor {
            close(fd)
            fileDescriptor = nil
        }

        isMonitoring = false
        print("✅ File monitor stopped")
    }

    /// Handle directory change event
    private func handleDirectoryChange(parser: JSONLParser) async {
        // Scan directory for .jsonl files
        await scanAndProcessFiles(parser: parser)
    }

    /// Scan directory and process all .jsonl files that have changed
    private func scanAndProcessFiles(parser: JSONLParser) async {
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: watchDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in contents {
                // Only process .jsonl files
                guard fileURL.pathExtension == "jsonl" else { continue }

                // Check if file has been modified since we last processed it
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modDate = attributes[.modificationDate] as? Date {

                    let relativePath = fileURL.lastPathComponent
                    let lastSeen = lastModificationTimes[relativePath] ?? .distantPast

                    if modDate > lastSeen {
                        print("📝 Detected change: \(relativePath)")
                        lastModificationTimes[relativePath] = modDate

                        // Process the file
                        do {
                            try await parser.processFile(fileURL)
                        } catch {
                            print("❌ Error processing \(relativePath): \(error)")
                        }
                    }
                }
            }
        } catch {
            print("❌ Error scanning directory: \(error)")
        }
    }

    /// Start polling backup timer (2 second interval)
    private func startPollingBackup() async {
        // Use a Task-based polling loop instead of Timer for actor compatibility
        Task { [weak self] in
            while await self?.isMonitoring ?? false {
                // Sleep for 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                // Scan and process files
                if let self = await self {
                    await self.scanAndProcessFiles(parser: await self.parser)
                }
            }
        }
    }

    /// Stop polling backup timer
    private func stopPollingBackup() async {
        // Polling will stop automatically when isMonitoring becomes false
    }

    /// Process all existing files on startup
    func processExistingFiles() async throws {
        print("📚 Processing existing files in \(watchDirectory.path)...")

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: watchDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var fileCount = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }

            do {
                try await parser.processFile(fileURL)
                fileCount += 1
            } catch {
                print("❌ Error processing existing file \(fileURL.lastPathComponent): \(error)")
            }
        }

        print("✅ Processed \(fileCount) existing file(s)")
    }
}

/// Errors that can occur during file monitoring
enum FileMonitorError: Error, CustomStringConvertible {
    case directoryNotFound(String)
    case cannotOpenDirectory(String)

    var description: String {
        switch self {
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .cannotOpenDirectory(let path):
            return "Cannot open directory for monitoring: \(path)"
        }
    }
}
