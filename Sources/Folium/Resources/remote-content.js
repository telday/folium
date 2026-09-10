// Reports Content-Security-Policy refusals to the app, so a document whose
// remote images the CSP blocked can say so instead of just missing them
// (issue #19).
//
// The browser fires `securitypolicyviolation` *before* it opens a
// connection, so listening here observes the refusal without any request
// leaving the machine. Reporting what the engine refused, rather than
// re-scanning the document in Swift for URLs that look remote, keeps one
// authority on what "blocked" means.
//
// `window.webkit.messageHandlers` is WebKit's page-to-native channel, and
// it is absent whenever nothing registered a handler of that name — every
// integration test that loads this shell into a bare WKWebView, for one. A
// missing channel has to be survivable, not fatal, or the shell's remaining
// scripts never run.
(function () {
  var handlers = window.webkit && window.webkit.messageHandlers;
  var channel = handlers && handlers.foliumRemoteContent;
  if (!channel) {
    return;
  }

  document.addEventListener("securitypolicyviolation", function (event) {
    channel.postMessage({
      kind: "violation",
      // Safari reports the specific sub-directive that refused the load
      // (`img-src-elem`) in `effectiveDirective`, and the directive as it
      // was written in the policy (`img-src`) in `violatedDirective`.
      directive: event.effectiveDirective || event.violatedDirective || "",
      blockedURI: event.blockedURI || ""
    });
  });

  // Called by FoliumRenderBody before it swaps in new content: what was
  // blocked belongs to the document that was on screen, not the one
  // replacing it. Posted from here rather than from Swift because Swift
  // would be doing it in the middle of a SwiftUI view update, which is
  // where SwiftUI refuses to accept published changes.
  window.FoliumDocumentWillRender = function () {
    channel.postMessage({ kind: "willRender" });
  };
})();
