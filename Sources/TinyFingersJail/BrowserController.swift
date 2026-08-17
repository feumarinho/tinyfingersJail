import Cocoa
import WebKit

/// O "navegador" embutido: um WKWebView preso ao site configurado.
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let containerView = NSView()
    let overlay: OverlayView

    private let config: Config
    private var webView: WKWebView!
    private var retryWork: DispatchWorkItem?

    init(config: Config) {
        self.config = config
        self.overlay = OverlayView(frame: .zero)
        super.init()
        buildWebView()
    }

    private func buildWebView() {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = [] // som/animação sem precisar clicar antes
        configuration.userContentController.addUserScript(BrowserController.hardeningScript())

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor
        containerView.addSubview(webView)

        overlay.autoresizingMask = [.width, .height]
        containerView.addSubview(overlay)
    }

    func layoutSubviews() {
        webView.frame = containerView.bounds
        overlay.frame = containerView.bounds
        overlay.needsLayout = true
    }

    func loadHome() {
        retryWork?.cancel()
        webView.load(URLRequest(url: config.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    /// Impede que a página abra menus de contexto, seleção de texto e arrastar imagens.
    private static func hardeningScript() -> WKUserScript {
        let source = """
        (function () {
          var block = function (event) { event.preventDefault(); };
          document.addEventListener('contextmenu', block, true);
          document.addEventListener('dragstart', block, true);
          var style = document.createElement('style');
          style.textContent = '* { -webkit-user-select: none !important; user-select: none !important; -webkit-user-drag: none !important; }';
          (document.head || document.documentElement).appendChild(style);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // Só o site configurado. Um clique acidental em anúncio/link externo não leva a lugar nenhum.
        decisionHandler(config.allows(host: url.host) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadHome()
    }

    private func scheduleRetry(_ error: Error) {
        let nsError = error as NSError
        // -999 é navegação cancelada por nós mesmos; não é falha de verdade.
        guard nsError.code != NSURLErrorCancelled else { return }

        overlay.showHint("Sem conexão com o site. Tentando de novo…", duration: 5)
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadHome() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil // nada de janelas novas
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }
}
