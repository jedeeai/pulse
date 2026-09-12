import Foundation

/// 基于 FSEvents 的目录树监听（对应原版 Nexus 的 fs.watch）。
/// 监听若干根目录，任意子文件变动时（系统层 1s + 自己 debounce 0.8s 合并）回调一次。
/// 平时完全不占 CPU，只有文件真变了才触发。
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.jedee.pulse.fswatch")
    private var debounce: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleFire()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency：系统先合并 1 秒内的事件
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func scheduleFire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
