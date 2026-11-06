import AppKit
import SwiftUI
import WebKit

/// Shows the lookup sections in a web view so dictionary entries keep the full layout
/// and styling Dictionary.app gives them (senses, examples + translations, links).
struct DictionaryEntryWebView: NSViewRepresentable {
    /// Page built by `LookupHTML`.
    let html: String
    /// Dark page (the dictionaries' CSS follows the color scheme).
    let isDark: Bool
    var onSpeak: (String) -> Void
    var onOpenWord: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: LookupHTML.messageChannel)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSpeak = onSpeak
        coordinator.onOpenWord = onOpenWord
        // Dictionary CSS follows the color scheme: match it to the page's text color.
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: LookupHTML.baseURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: LookupHTML.messageChannel)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loadedHTML: String?
        var onSpeak: (String) -> Void = { _ in }
        var onOpenWord: (String) -> Void = { _ in }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: String] else { return }
            if let text = body["speak"] {
                onSpeak(text)
            } else if let word = body["open"] {
                onOpenWord(word)
            }
        }

        /// Only our own page and the entry frames load; clicks on links are handled in JS.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType != .linkActivated,
                  let scheme = navigationAction.request.url?.scheme?.lowercased(),
                  ["about", "blob", LookupHTML.baseURL.scheme ?? ""].contains(scheme)
            else { return .cancel }
            return .allow
        }
    }
}

// MARK: - Page

/// Builds the page shown in `DictionaryEntryWebView`.
enum LookupHTML {
    static let messageChannel = "lumio"
    /// Gives the page a real origin so the entry frames (blob URLs) are same-origin
    /// and can be measured. Nothing is fetched from it.
    static let baseURL = URL(string: "lumio-lookup://entry/")!

    struct Style: Equatable {
        var text: String
        var secondary: String
        var muted: String
        var divider: String
        var fontSize: Double
        var isDark: Bool
    }

    /// A word's entries laid out like Dictionary.app: each dictionary's records one after
    /// another (headword, pronunciation, senses), under the dictionary's name.
    static func entriesDocument(_ entries: [DictionaryEntry], style: Style) -> String {
        var records: [String] = []
        let body = entries.map { entry -> String in
            switch entry {
            case let .html(dictionaryName, entryRecords):
                var html = "<section><div class=\"dict-name\">\(escape(dictionaryName))</div>"
                for record in entryRecords {
                    html += "<iframe class=\"entry\" data-record=\"\(records.count)\" scrolling=\"no\"></iframe>"
                    records.append(prepare(record: record, style: style))
                }
                return html + "</section>"
            case let .text(text):
                return "<section><p class=\"plain\">\(escape(text))</p></section>"
            }
        }.joined()
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>\(pageCSS(style))
        body { padding: 4px 14px 24px 2px; }
        section + section { margin-top: 22px; padding-top: 16px; }
        .dict-name { font-size: \(cssNumber(style.fontSize - 4))px; font-weight: 600; letter-spacing: .06em;
                     text-transform: uppercase; color: \(style.muted); margin-bottom: 8px; }
        </style>
        </head><body>
        \(body)
        <script type="application/json" id="records">\(json(records))</script>
        <script>\(script)</script>
        </body></html>
        """
    }

    /// Tightens a record for the narrow panel: no page margins, theme font size and text
    /// color, transparent background. The dictionary's own CSS handles everything else.
    private static func prepare(record: String, style: Style) -> String {
        let override = """
        <style type="text/css">
        :root { color-scheme: light dark; }
        html { overflow: hidden; background: transparent !important; }
        body { margin: 0 !important; padding: 0 !important; display: flow-root;
               background: transparent !important; color: \(style.text);
               font-size: \(cssNumber(style.fontSize))px !important; }
        </style>
        """
        let html = expandSelfClosingTags(record)
        if let headEnd = html.range(of: "</head>") {
            return html.replacingCharacters(in: headEnd.lowerBound..<headEnd.lowerBound, with: override)
        }
        return override + html
    }

    /// Records are XHTML but carry no XHTML namespace, so they only style correctly when
    /// parsed as HTML. HTML ignores the "/" in `<span/>` and would leave it open: write
    /// such tags out as `<span></span>` first (void tags like `<br/>` are fine as they are).
    private static func expandSelfClosingTags(_ record: String) -> String {
        record.replacingOccurrences(
            of: #"<(?!(?:area|base|br|col|embed|hr|img|input|link|meta|source|track|wbr)\b)([A-Za-z][\w:.-]*)(\s[^<>]*?)?\s*/>"#,
            with: "<$1$2></$1>",
            options: .regularExpression
        )
    }

    private static func pageCSS(_ style: Style) -> String {
        let size = style.fontSize
        return """
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font: \(cssNumber(size))px -apple-system, sans-serif; color: \(style.text);
               padding: 2px 4px 20px 2px; -webkit-user-select: text; cursor: default; }
        section + section { border-top: 1px solid \(style.divider); margin-top: 16px; padding-top: 14px; }
        .head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; }
        .label { font-size: \(cssNumber(size - 3))px; font-weight: 700; letter-spacing: .06em;
                 text-transform: uppercase; color: \(style.muted); }
        .inline-word { font-family: ui-serif, Georgia, serif; color: \(style.secondary); }
        .source { margin-left: auto; font-size: \(cssNumber(size - 3))px; color: \(style.muted);
                  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .speak { flex: none; align-self: center; border: 0; background: none; padding: 2px;
                 color: \(style.muted); cursor: pointer; line-height: 0; }
        .source + .speak { margin-left: 0; }
        .label + .speak, .inline-word + .speak { margin-left: auto; }
        .speak:hover { color: \(style.text); }
        .speak svg { width: 14px; height: 14px; }
        .word { margin: 0 0 6px; font: \(cssNumber(size + 2))px ui-serif, Georgia, serif; }
        .plain { margin: 0; font: \(cssNumber(size))px/1.5 ui-serif, Georgia, serif;
                 color: \(style.secondary); white-space: pre-wrap; }
        .missing { margin: 0; color: \(style.muted); font-style: italic; }
        iframe.entry { display: block; width: 100%; height: 0; border: 0; overflow: hidden; }
        iframe.entry + iframe.entry { margin-top: 12px; }
        """
    }

    /// Loads each record into its own frame (dictionaries ship clashing CSS), sizes the frame
    /// to its content, and routes speaker buttons and entry links back to Swift.
    private static let script = """
    const post = (message) => window.webkit.messageHandlers.\(messageChannel).postMessage(message);
    document.addEventListener('click', (event) => {
      const button = event.target.closest('[data-speak]');
      if (button) post({ speak: button.dataset.speak });
    });
    const records = JSON.parse(document.getElementById('records').textContent);
    for (const frame of document.querySelectorAll('iframe[data-record]')) {
      frame.addEventListener('load', () => {
        const doc = frame.contentDocument;
        if (!doc || !doc.body) return;
        const root = doc.body;
        const fit = () => { frame.style.height = Math.ceil(root.getBoundingClientRect().height) + 'px'; };
        fit();
        new ResizeObserver(fit).observe(root);
        doc.addEventListener('click', (event) => {
          const link = event.target.closest && event.target.closest('a');
          if (!link) return;
          event.preventDefault();
          const word = (link.getAttribute('title') || link.textContent || '').trim();
          if (word) post({ open: word });
        });
      });
      const record = records[Number(frame.dataset.record)];
      frame.src = URL.createObjectURL(new Blob([record], { type: 'text/html;charset=utf-8' }));
    }
    """
    // MARK: - Helpers

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// JSON for a <script> block. JSONSerialization escapes "/", so "</script>" can't occur.
    private static func json(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private static func cssNumber(_ value: Double) -> String {
        String(format: "%.1f", max(8, value))
    }
}
