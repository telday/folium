// Defines window.FoliumScrollBy(lines), which Swift calls via
// evaluateJavaScript when a scroll key is pressed (MarkdownWebView).
//
// The key itself is never seen here. Capturing it with a keydown listener in
// the page would only work while the web content held focus, and would take
// the keystroke out of the responder chain before menus, key equivalents and
// VoiceOver ever saw it — so the capture is a native NSEvent one and this end
// only moves the viewport.
window.FoliumScrollBy = function (lines) {
  var article = document.getElementById("markdown-content");
  var style = window.getComputedStyle(article);

  // Resolves to a pixel value while the stylesheet gives the body a
  // line-height; the keyword "normal" parses as NaN, hence the fallback.
  var lineHeight = parseFloat(style.lineHeight);
  if (!isFinite(lineHeight) || lineHeight <= 0) {
    lineHeight = parseFloat(style.fontSize) * 1.5;
  }

  window.scrollBy({ top: lines * lineHeight, behavior: "smooth" });
};

// Defines window.FoliumScrollToAnchor(id), which Swift calls via
// evaluateJavaScript when NavigationPolicy.decide resolves an in-document
// link to .scrollToAnchor rather than letting WebKit navigate to it.
//
// Two ways to name a target, because a document has two ways to declare one.
// `getElementById` covers `<h2 id="install">`; the `getElementsByName`
// fallback covers `<a name="install"></a>`, the older form that raw HTML
// brought back into reach (issue #20) — the whole point of that anchor is
// that `#install` scrolls to it, so rendering the element without finding it
// would fix half the row and leave the symptom.
//
// cmark-gfm does not emit `id` attributes on headings (verified against this
// shell), so a `#some-heading` link still has no element to find here —
// tracked separately, and no fallback here can invent an id nothing wrote.
// The no-op below is what keeps that gap from surfacing as a JS exception in
// the console instead.
window.FoliumScrollToAnchor = function (id) {
  var target = document.getElementById(id) || document.getElementsByName(id)[0];
  if (!target) {
    return;
  }
  target.scrollIntoView({ behavior: "smooth" });
};
