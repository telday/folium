import Foundation
import UniformTypeIdentifiers
import WebKit

/// A `WKURLSchemeHandler` for the private `folium-doc:` scheme (issue #18):
/// reads a document-relative resource's bytes on the app's own process,
/// which is unsandboxed (ADR 0003), and hands them to the web content
/// process. The web content process itself gets no filesystem grant at all —
/// see `docs/adr/0007-document-resources-via-url-scheme.md` for why that
/// replaced widening `loadFileURL`'s read-access grant.
///
/// One instance per open document: `MarkdownWebView` constructs it with that
/// document's own directory and registers it on the `WKWebViewConfiguration`
/// before creating the web view, because
/// `setURLSchemeHandler(_:forURLScheme:)` cannot be called afterwards.
///
/// This is deliberately thin. The only decision that matters — which files a
/// document is allowed to reach — lives in `DocumentResourceResolver`, which
/// has no WebKit dependency and is unit-tested; this type's job is bridging
/// that decision to the three `WKURLSchemeTask` callbacks WebKit expects.
final class DocumentResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let documentDirectory: URL

    /// Tasks WebKit has already told us to stop. Responding to a
    /// `WKURLSchemeTask` after `stop(_:)` raises an Objective-C exception
    /// rather than failing gracefully — WebKit can call `stop` if the page
    /// navigates away while a read is still in flight — so every response
    /// path below checks this first. `WKURLSchemeTask` is a reference type
    /// even though it's expressed as a protocol, which is what makes
    /// `ObjectIdentifier` a valid way to key this set.
    private var stoppedTasks = Set<ObjectIdentifier>()

    init(documentDirectory: URL) {
        self.documentDirectory = documentDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = DocumentResourceResolver.fileURL(for: requestURL, documentDirectory: documentDirectory),
              let data = try? Data(contentsOf: fileURL)
        else {
            complete(urlSchemeTask) { $0.didFailWithError(CocoaError(.fileReadNoSuchFile)) }
            return
        }

        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
        // An explicit Content-Length rather than leaning on WebKit to infer
        // one from however much data eventually arrives: this handler always
        // has the whole file in memory before it sends anything, so the real
        // length is already known up front.
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType ?? "application/octet-stream",
                "Content-Length": String(data.count)
            ]
        )
        guard let response else {
            complete(urlSchemeTask) { $0.didFailWithError(CocoaError(.fileReadUnknown)) }
            return
        }

        complete(urlSchemeTask) { task in
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }

    /// Runs `body` unless `task` was already stopped, checked right before
    /// acting rather than once at the top of `webView(_:start:)` — the
    /// resolver call and the file read both take real time, during which a
    /// fast navigation away can still land a `stop(_:)` call.
    private func complete(_ task: WKURLSchemeTask, _ body: (WKURLSchemeTask) -> Void) {
        guard !stoppedTasks.contains(ObjectIdentifier(task)) else { return }
        body(task)
    }
}
