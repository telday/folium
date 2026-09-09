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

    init(documentDirectory: URL) {
        self.documentDirectory = documentDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = DocumentResourceResolver.fileURL(for: requestURL, documentDirectory: documentDirectory),
              let data = try? Data(contentsOf: fileURL)
        else {
            // A refused or unreadable resource fails the request rather than
            // returning empty bytes: a failure is a visibly broken image or
            // dead link, which `CONTEXT.md`'s first floor asks for, where a
            // zero-length 200 would render as nothing at all.
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
