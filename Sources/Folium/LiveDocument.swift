import Combine
import Foundation

private let benchMarker = BenchMarker()

/// One open document's body HTML, kept in step with the file on disk
/// (issue #7).
///
/// SwiftUI's `DocumentGroup` reads the file once and hands over the content as
/// a plain value, so the ongoing relationship with the file has to be owned
/// somewhere. This is that owner: `FileWatcher` reports changes,
/// `ReloadCoalescer` collapses a save's burst into one, and this re-reads and
/// re-renders.
///
/// It publishes **body HTML** rather than text so a render costs one per real
/// change rather than one per SwiftUI view update — switching tabs is not
/// supposed to re-render anything.
@MainActor
final class LiveDocument: ObservableObject {
    /// The rendered document body, ready to hand to `MarkdownWebView`.
    @Published private(set) var bodyHTML: String

    private let fileURL: URL?
    private var coalescer: ReloadCoalescer?
    private var watcher: FileWatcher?

    /// - Parameters:
    ///   - text: the Markdown the document was opened with.
    ///   - fileURL: the file backing it, or `nil` for a document with nothing
    ///     on disk, which simply gets no live-reload.
    ///   - scheduler: how the coalescing window is timed.
    init(
        text: String,
        fileURL: URL?,
        scheduler: any ReloadScheduler = SleepingReloadScheduler()
    ) {
        self.fileURL = fileURL
        bodyHTML = LiveDocument.rendered(from: text, fileURL: fileURL)

        guard let fileURL else { return }
        coalescer = ReloadCoalescer(scheduler: scheduler) { [weak self] in
            self?.reloadFromDisk()
        }
        let watcher = FileWatcher(url: fileURL) { [weak self] in
            Task { @MainActor in self?.fileDidChange() }
        }
        // A file that can't be watched still has a perfectly good document on
        // screen. Live-reload is what's missing, not the document.
        watcher.start()
        self.watcher = watcher
    }

    /// Records that the file changed. The watcher calls this on every
    /// notification; the reload follows once the burst settles.
    func fileDidChange() {
        coalescer?.noteChange()
    }

    /// Re-reads the file and re-renders, unless the output would be identical.
    ///
    /// A failed read or decode keeps the last good body. A file that is briefly
    /// missing, or briefly invalid UTF-8, is the normal middle of a save rather
    /// than something to report; blanking the window on the way past would be
    /// worse than content a few milliseconds stale. (What to do about a file
    /// that stays undecodable is an open question in CONTEXT.md, and belongs to
    /// the code that opens documents, not here.)
    private func reloadFromDisk() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let text = try? MarkdownLoading.text(fromUTF8: data) else { return }

        let rendered = LiveDocument.rendered(from: text, fileURL: fileURL)
        // `touch`, chmod, or a save of unchanged bytes: no publish, no
        // injection into the web view, no repaint.
        guard rendered != bodyHTML else { return }
        bodyHTML = rendered
        // `reload-paint` is marked once the web view confirms the repaint
        // actually landed, not here — see `MarkdownWebViewState
        // .paintEventToConfirm`. Publishing this is the trigger, not the
        // measured moment.
    }

    /// Renders `text` and, if the document has a real file behind it,
    /// resolves its `src`/`href` values against the file's own directory
    /// (`DocumentRelativeLinks`, issue #18) so sibling images and links
    /// work. A document with nothing on disk — `DocumentGroup` can hand
    /// over one of these — has no directory to resolve against, so it
    /// simply keeps whatever relative references the render produced.
    private static func rendered(from text: String, fileURL: URL?) -> String {
        benchMarker.measure("render-start", "render-end", reportAs: "render") {
            let html = MarkdownRenderer.renderHTML(from: text)
            guard let directory = fileURL?.deletingLastPathComponent() else { return html }
            return DocumentRelativeLinks.resolve(html, relativeTo: directory)
        }
    }
}
