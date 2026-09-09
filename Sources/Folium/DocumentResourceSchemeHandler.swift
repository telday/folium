import Foundation
import UniformTypeIdentifiers
import WebKit

/// A `WKURLSchemeHandler` for the private `folium-doc:` scheme (issue #18).
/// Reads a document-relative resource's bytes on the app's own process,
/// which is unsandboxed (ADR 0003), and hands them to the web content
/// process. That process receives no filesystem grant of its own. See
/// [ADR 0007](../../docs/adr/0007-document-resources-via-url-scheme.md).
///
/// One instance per open document, built with that document's directory and
/// registered by `MarkdownWebView.configuration(documentDirectory:)`.
///
/// Thin on purpose: which files a document may reach is decided by
/// `DocumentResourceResolver`, and this only bridges that decision to the
/// `WKURLSchemeTask` callbacks WebKit expects.
final class DocumentResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let documentDirectory: URL

    init(documentDirectory: URL) {
        self.documentDirectory = documentDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = DocumentResourceResolver.fileURL(for: requestURL, documentDirectory: documentDirectory),
              let data = try? Data(contentsOf: fileURL)
        else {
            // Fails the request rather than answering with empty bytes. A
            // failure draws a broken image the reader can see; a
            // zero-length 200 renders as nothing, which is the silent
            // omission this app must never produce.
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
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
            urlSchemeTask.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// Nothing to cancel. Responding to a `WKURLSchemeTask` after WebKit has
    /// stopped it raises an Objective-C exception rather than failing
    /// gracefully, so a handler that finishes its work *later* — off the main
    /// thread, or after an `await` — must track which tasks were stopped and
    /// check before every callback. `webView(_:start:)` above instead
    /// resolves, reads, and responds without ever yielding, so by the time
    /// WebKit can deliver this call the task is already finished and this
    /// handler holds no reference to it.
    ///
    /// Making that read asynchronous would reintroduce the window and this
    /// method's obligation along with it.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
