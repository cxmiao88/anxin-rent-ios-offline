import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// 应用入口：H5 资源打进 App 包内，用自定义协议本地加载，接口走壳内同源代理。
@main
struct AnxinRentApp: App {
    var body: some Scene {
        WindowGroup {
            WebShellView()
                .ignoresSafeArea(edges: [.bottom])
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - 常量

/// 自定义协议。页面地址形如 anxin://app/h5/index.html，
/// H5 里 /h5/ 开头的绝对资源路径会自然解析到同一个协议下，由 LocalSiteSchemeHandler 从包内读文件。
private let kScheme = "anxin"
private let kHost = "app"
private let kOrigin = "\(kScheme)://\(kHost)"
private let kHomeURL = "\(kOrigin)/h5/index.html"
/// 真实后端域名。H5 里写死的绝对接口地址会在 JS 层改写到 kOrigin，再由壳代理转发到这里。
private let kServerOrigin = "https://cc.scxjydz.com"

struct WebShellView: UIViewRepresentable {

    func makeCoordinator() -> WebCoordinator {
        WebCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = WKWebsiteDataStore.default()

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // 本地资源 + 接口代理
        config.setURLSchemeHandler(LocalSiteSchemeHandler(), forURLScheme: kScheme)

        // 把写死的 https://cc.scxjydz.com 改写到本地协议，保证接口与页面同源（后端没有 CORS 头）
        let rewriteScript = WKUserScript(source: Self.originRewriteJS,
                                         injectionTime: .atDocumentStart,
                                         forMainFrameOnly: false)
        config.userContentController.addUserScript(rewriteScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // 让 H5 里的 uni-app 识别为 App 环境时也别乱认，这里只改 UA 尾巴便于排查
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            guard let ua = value as? String else { return }
            webView.customUserAgent = ua + " AnxinRentShell/1.0"
        }

        context.coordinator.load(webView: webView, urlString: kHomeURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// fetch / XHR / sendBeacon 的地址改写
    private static let originRewriteJS = """
    (function () {
      var SERVER = '\(kServerOrigin)';
      var LOCAL = '\(kOrigin)';
      function rw(u) {
        if (typeof u !== 'string') return u;
        if (u.indexOf(SERVER) === 0) return LOCAL + u.slice(SERVER.length);
        return u;
      }
      try {
        if (window.fetch) {
          var of = window.fetch;
          window.fetch = function (input, init) {
            if (typeof input === 'string') {
              input = rw(input);
            } else if (input && input.url) {
              var nu = rw(input.url);
              if (nu !== input.url) {
                input = new Request(nu, { method: input.method, headers: input.headers, body: input.body, mode: 'same-origin', credentials: 'include', cache: input.cache, redirect: input.redirect });
              }
            }
            return of.call(window, input, init);
          };
        }
      } catch (e) {}
      try {
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (m, u) {
          var args = Array.prototype.slice.call(arguments);
          args[1] = rw(u);
          return oo.apply(this, args);
        };
      } catch (e) {}
      try {
        if (navigator.sendBeacon) {
          var ob = navigator.sendBeacon.bind(navigator);
          navigator.sendBeacon = function (u, d) { return ob(rw(u), d); };
        }
      } catch (e) {}
    })();
    """
}

// MARK: - WKWebView 代理

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate {

    private weak var webView: WKWebView?
    private var uploadCompletion: (([URL]?) -> Void)?

    func load(webView: WKWebView, urlString: String) {
        self.webView = webView
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20
        webView.load(request)
    }

    // 允许访问范围内的站点
    private let allowedHostSuffixes = [
        "scxjydz.com",
        "bspapp.com",
        "dcloud.io",
        "dcloud.net.cn",
        "weixin.qq.com",
        "map.baidu.com",
        "apis.map.qq.com",
        "restapi.amap.com",
        "amap.com",
        "aliyuncs.com"
    ]

    private func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == kScheme { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return true }
        return allowedHostSuffixes.contains { host.hasSuffix($0) || host.contains($0) }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }

        switch url.scheme?.lowercased() {
        case "http", "https", kScheme:
            if isAllowed(url) {
                decisionHandler(.allow)
            } else if navigationAction.targetFrame == nil {
                // 新窗口打开的第三方页（如微信 H5 支付、地图页）交给系统浏览器
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
            } else {
                // 站内可跳的第三方资源（CDN、字体、统计）直接放行
                decisionHandler(.allow)
            }
        case "tel", "sms", "mailto", "weixin", "alipays", "alipay", "itms-apps", "itms-services":
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        default:
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure()
    }

    private func handleLoadFailure() {
        guard let webView = webView else { return }
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0;font-family:-apple-system;display:flex;height:100vh;align-items:center;justify-content:center;background:#f7f7f7;">
        <div style="text-align:center;color:#666;">
        <div style="font-size:17px;margin-bottom:12px;">页面没能加载出来</div>
        <a href="\(kHomeURL)" style="color:#1a73e8;font-size:15px;text-decoration:none;">点这里重试</a>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: 文件/图片上传（H5 的 <input type="file">）
    // WKOpenPanelParameters 在 Xcode 16.4 的 SDK 里被标为 iOS 18.4+，但该类从 iOS 8 就已经存在，
    // 这里加 @available 只为过编译，运行时在旧系统上仍能被 WKWebView 正常回调。
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {

        uploadCompletion = completionHandler
        let types: [UTType] = [.image, .movie, .pdf, .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.delegate = self
        topViewController()?.present(picker, animated: true, completion: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        uploadCompletion?(urls)
        uploadCompletion = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        uploadCompletion?(nil)
        uploadCompletion = nil
    }

    // MARK: JS alert / confirm

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        topViewController()?.present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        topViewController()?.present(alert, animated: true, completion: nil)
    }
}

// MARK: - 本地资源与接口代理

final class LocalSiteSchemeHandler: NSObject, WKURLSchemeHandler {

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 包内 www 目录
    private lazy var bundleRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("www", isDirectory: true)

    private var running: [ObjectIdentifier: URLSessionDataTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(ShellError.badURL); return
        }
        let path = url.path
        if path.hasPrefix("/api/") || path == "/api" {
            proxy(urlSchemeTask)
        } else {
            serveLocal(path: path, task: urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        if let t = running.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) {
            t.cancel()
        }
    }

    // MARK: 本地文件

    private func serveLocal(path: String, task: WKURLSchemeTask) {
        guard let root = bundleRoot else {
            task.didFailWithError(ShellError.noBundle); return
        }
        var rel = path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "h5/index.html" }
        if rel.hasSuffix("/") { rel += "index.html" }

        let fileURL = root.appendingPathComponent(rel)
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
            send(file: fileURL, task: task)
            return
        }
        let indexURL = fileURL.appendingPathComponent("index.html")
        if fm.fileExists(atPath: indexURL.path) {
            send(file: indexURL, task: task)
            return
        }
        // 无扩展名的路径当作前端路由，回落到首页（hash 路由下基本用不到）
        if !rel.contains(".") {
            let homeURL = root.appendingPathComponent("h5/index.html")
            if fm.fileExists(atPath: homeURL.path) {
                send(file: homeURL, task: task)
                return
            }
        }
        task.didFailWithError(ShellError.notFound(rel))
    }

    private func send(file: URL, task: WKURLSchemeTask) {
        do {
            let data = try Data(contentsOf: file)
            let mime = Self.mimeType(for: file.pathExtension)
            var headers: [String: String] = [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-cache"
            ]
            if mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") {
                headers["Access-Control-Allow-Origin"] = "*"
            }
            if let resp = HTTPURLResponse(url: file, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
                task.didReceive(resp)
            }
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "eot": return "application/vnd.ms-fontobject"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: 接口代理

    private func proxy(_ task: WKURLSchemeTask) {
        guard let localURL = task.request.url,
              var comps = URLComponents(url: localURL, resolvingAgainstBaseURL: false) else {
            task.didFailWithError(ShellError.badURL); return
        }
        comps.scheme = "https"
        comps.host = "cc.scxjydz.com"
        comps.port = nil
        guard let target = comps.url else {
            task.didFailWithError(ShellError.badURL); return
        }

        let original = task.request
        var req = URLRequest(url: target)
        req.httpMethod = original.httpMethod
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData

        for (key, value) in original.allHTTPHeaderFields ?? [:] {
            let lower = key.lowercased()
            if ["origin", "referer", "host", "cookie", "content-length", "accept-encoding"].contains(lower) { continue }
            req.setValue(value, forHTTPHeaderField: key)
        }

        if let body = original.httpBody {
            req.httpBody = body
        } else if let stream = original.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 8192)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            req.httpBody = data
        }

        let dataTask = session.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error = error {
                    task.didFailWithError(error)
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    task.didFailWithError(ShellError.badResponse)
                    return
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    guard let key = k as? String else { continue }
                    let lower = key.lowercased()
                    if ["content-encoding", "transfer-encoding", "content-length"].contains(lower) { continue }
                    headers[key] = "\(v)"
                }
                if let body = data {
                    headers["Content-Length"] = String(body.count)
                }
                headers["Access-Control-Allow-Origin"] = "*"
                if let out = HTTPURLResponse(url: localURL, statusCode: http.statusCode,
                                             httpVersion: "HTTP/1.1", headerFields: headers) {
                    task.didReceive(out)
                }
                if let body = data, !body.isEmpty {
                    task.didReceive(body)
                }
                task.didFinish()
            }
        }
        running[ObjectIdentifier(task)] = dataTask
        dataTask.resume()
    }
}

enum ShellError: LocalizedError {
    case badURL
    case noBundle
    case notFound(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badURL: return "本地地址无效"
        case .noBundle: return "包内缺少 www 资源目录"
        case .notFound(let path): return "包内找不到资源：\(path)"
        case .badResponse: return "接口返回异常"
        }
    }
}

// MARK: - 工具

func topViewController() -> UIViewController? {
    let keyWindow = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }

    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}
