import SwiftUI
import WebKit
import Network
import UniformTypeIdentifiers

/// 应用入口。
/// H5 资源打进 App 包内，由 App 内部起的本地 HTTP 服务提供（http://127.0.0.1:随机端口/h5/...），
/// 这样页面处在正常的 http 源上：ES module、localStorage、同源请求都成立。
/// 所有不是包内静态文件的请求（也就是接口 /api/... 之类）由同一个服务代转到真实后端。

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

private let kBackendOrigin = "https://cc.scxjydz.com"
private let kBackendHost = "cc.scxjydz.com"
private let kLogName = "shell.log"

/// 全局壳环境：启动本地服务、给出首页地址
final class ShellEnvironment {
    static let shared = ShellEnvironment()

    let wwwRoot: URL
    private(set) var port: UInt16 = 0
    private let server: LocalHTTPServer

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var homeURL: String { baseURL + "/h5/index.html" }
    var started: Bool { port != 0 }

    private init() {
        if let res = Bundle.main.resourceURL {
            wwwRoot = res.appendingPathComponent("www", isDirectory: true)
        } else {
            wwwRoot = Bundle.main.bundleURL.appendingPathComponent("www", isDirectory: true)
        }
        server = LocalHTTPServer(root: wwwRoot)
        port = (try? server.start()) ?? 0
    }
}

// MARK: - 日志

enum ShellLog {
    static func path() -> String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent(kLogName)
    }

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let p = path()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let size = attrs[.size] as? Int, size > 300_000 {
            try? FileManager.default.removeItem(atPath: p)
        }
        if let handle = FileHandle(forWritingAtPath: p) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: p))
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: path())
    }
}

// MARK: - WebView

struct WebShellView: UIViewRepresentable {

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let env = ShellEnvironment.shared
        ShellLog.write("启动 http=\(env.baseURL) www=\(env.wwwRoot.path)")

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = WKWebsiteDataStore.default()

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        let controller = config.userContentController
        controller.add(context.coordinator, name: "anxinlog")
        controller.addUserScript(WKUserScript(source: Self.rewriteJS(base: env.baseURL),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.logJS(),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.load(webView: webView, urlString: env.homeURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// 把写死的后端域名改写到本地服务（同源），fetch / XHR / sendBeacon 全覆盖
    private static func rewriteJS(base: String) -> String {
        """
        (function () {
          var SERVER = '\(kBackendOrigin)';
          var LOCAL = '\(base)';
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
                    try {
                      input = new Request(nu, { method: input.method, headers: input.headers, body: input.body, mode: 'same-origin', credentials: 'include', cache: input.cache, redirect: input.redirect });
                    } catch (e2) {
                      // 构造失败就退回原始 Request，不让整个 fetch 抛错
                    }
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

    /// 页面里的报错与 console 输出回传给原生，写进 Documents/shell.log 便于排查
    private static func logJS() -> String {
        """
        (function () {
          function send(level, args) {
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) {
                var a = args[i];
                try { parts.push((typeof a === 'string') ? a : JSON.stringify(a)); }
                catch (e) { parts.push(String(a)); }
              }
              var text = parts.join(' ').slice(0, 900);
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.anxinlog) {
                window.webkit.messageHandlers.anxinlog.postMessage(level + ': ' + text);
              }
            } catch (e) {}
          }
          ['log', 'warn', 'error'].forEach(function (k) {
            var orig = console[k] ? console[k].bind(console) : function () {};
            console[k] = function () { send(k, arguments); orig.apply(console, arguments); };
          });
          window.addEventListener('error', function (e) {
            send('error', ['onerror ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)]);
          });
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            send('error', ['unhandledrejection ' + (r && (r.stack || r.message) ? (r.stack || r.message) : String(r))]);
          });
          setTimeout(function () {
            try {
              send('log', ['after3s readyState=' + document.readyState +
                           ' bodyChildren=' + (document.body ? document.body.childElementCount : -1) +
                           ' scripts=' + document.scripts.length]);
            } catch (e) {}
          }, 3000);
        })();
        """
    }
}

// MARK: - WKWebView 代理

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                           WKScriptMessageHandler, UIDocumentPickerDelegate {

    private weak var webView: WKWebView?
    private var uploadCompletion: (([URL]?) -> Void)?

    func load(webView: WKWebView, urlString: String) {
        self.webView = webView
        guard let url = URL(string: urlString) else {
            ShellLog.write("首页地址无效: \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        ShellLog.write("加载首页 \(urlString)")
        webView.load(request)
    }

    // MARK: 页面日志

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "anxinlog" else { return }
        ShellLog.write("[js] \(message.body)")
    }

    // MARK: 导航策略

    private let allowedHostSuffixes = [
        "scxjydz.com", "bspapp.com", "dcloud.io", "dcloud.net.cn", "weixin.qq.com",
        "map.baidu.com", "apis.map.qq.com", "restapi.amap.com", "amap.com", "aliyuncs.com"
    ]

    private func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return true }
        return allowedHostSuffixes.contains { host.hasSuffix($0) || host.contains($0) }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if isAllowed(url) {
                decisionHandler(.allow)
            } else if navigationAction.targetFrame == nil {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        case "tel", "sms", "mailto", "weixin", "alipays", "alipay", "itms-apps", "itms-services":
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        default:
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ShellLog.write("页面加载完成 \(webView.url?.absoluteString ?? "")")
        webView.evaluateJavaScript(
            "(function(){try{return document.body?document.body.childElementCount:-1}catch(e){return -1}})()"
        ) { value, error in
            ShellLog.write("body 元素数=\(String(describing: value)) err=\(error?.localizedDescription ?? "nil")")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ShellLog.write("加载失败(provisional) \(error.localizedDescription)")
        handleLoadFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ShellLog.write("加载失败 \(error.localizedDescription)")
        handleLoadFailure()
    }

    private func handleLoadFailure() {
        guard let webView = webView else { return }
        let home = ShellEnvironment.shared.homeURL
        let logPath = ShellLog.path()
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0;font-family:-apple-system;display:flex;height:100vh;align-items:center;justify-content:center;background:#f7f7f7;">
        <div style="text-align:center;color:#666;padding:0 24px;">
        <div style="font-size:17px;margin-bottom:12px;">页面没能加载出来</div>
        <div style="font-size:13px;color:#999;word-break:break-all;">\(home)</div>
        <div style="font-size:12px;color:#bbb;margin-top:8px;word-break:break-all;">\(logPath)</div>
        <a href="\(home)" style="color:#1a73e8;font-size:15px;text-decoration:none;display:inline-block;margin-top:14px;">点这里重试</a>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: 文件/图片上传

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

// MARK: - 本地 HTTP 服务

/// 监听 127.0.0.1 的极简 HTTP/1.1 服务：
/// 命中包内 www 里的文件就直接返回；否则整条请求转给真实后端（不产生跨域问题）。
final class LocalHTTPServer {

    private let queue = DispatchQueue(label: "com.anxinhuiju.shell.http")
    private let root: URL
    private let backendHost = kBackendHost
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    init(root: URL) {
        self.root = root
    }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue { self?.port = p }
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        ShellLog.write("本地服务端口=\(port)")
        return port
    }

    // MARK: 连接

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        let parser = HTTPRequestParser()
        receive(connection, parser: parser)
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { parser.append(data) }
            if parser.isComplete {
                self.handle(connection, parser: parser)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, parser: parser)
        }
    }

    private func handle(_ connection: NWConnection, parser: HTTPRequestParser) {
        let method = parser.method.uppercased()
        ShellLog.write("\(method) \(parser.path)")

        if method == "OPTIONS" {
            respond(connection, status: 204, headerLines: [], body: Data(), reason: "No Content")
            return
        }
        if let file = localFile(for: parser.path) {
            serve(connection, file: file)
        } else {
            proxy(connection, parser: parser)
        }
    }

    // MARK: 静态文件

    private func localFile(for pathAndQuery: String) -> URL? {
        var path = pathAndQuery
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        guard let decoded = path.removingPercentEncoding else { return nil }
        var rel = decoded
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "h5/index.html" }
        if rel.hasSuffix("/") { rel += "index.html" }
        if rel.contains("..") { return nil }

        let file = root.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            let index = file.appendingPathComponent("index.html")
            return fm.fileExists(atPath: index.path) ? index : nil
        }
        return file
    }

    private func serve(_ connection: NWConnection, file: URL) {
        guard let data = try? Data(contentsOf: file) else {
            respond(connection, status: 500, headerLines: ["Content-Type: text/plain; charset=utf-8"],
                    body: Data("读取失败".utf8), reason: "Internal Server Error")
            return
        }
        let mime = Self.mimeType(for: file.pathExtension)
        respond(connection, status: 200,
                headerLines: ["Content-Type: \(mime)", "Cache-Control: no-cache"],
                body: data, reason: "OK")
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

    // MARK: 接口代转

    private func proxy(_ connection: NWConnection, parser: HTTPRequestParser) {
        var path = parser.path
        if !path.hasPrefix("/") { path = "/" + path }
        guard let target = URL(string: "https://\(backendHost)\(path)") else {
            respond(connection, status: 400, headerLines: ["Content-Type: text/plain; charset=utf-8"],
                    body: Data("地址无效".utf8), reason: "Bad Request")
            return
        }

        var request = URLRequest(url: target)
        request.httpMethod = parser.method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for (key, value) in parser.headers {
            let lower = key.lowercased()
            if ["host", "origin", "referer", "content-length", "accept-encoding",
                "connection", "proxy-connection", "keep-alive"].contains(lower) { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        let method = parser.method.uppercased()
        if method != "GET" && method != "HEAD" && !parser.body.isEmpty {
            request.httpBody = parser.body
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                ShellLog.write("代理失败 \(path) \(error.localizedDescription)")
                self.respond(connection, status: 502,
                             headerLines: ["Content-Type: text/plain; charset=utf-8"],
                             body: Data("接口转发失败: \(error.localizedDescription)".utf8),
                             reason: "Bad Gateway")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.respond(connection, status: 502,
                             headerLines: ["Content-Type: text/plain; charset=utf-8"],
                             body: Data("接口响应异常".utf8), reason: "Bad Gateway")
                return
            }
            var lines: [String] = []
            var hasContentType = false
            for (k, v) in http.allHeaderFields {
                guard let key = k as? String else { continue }
                let lower = key.lowercased()
                if ["transfer-encoding", "content-encoding", "content-length",
                    "connection", "keep-alive"].contains(lower) { continue }
                if lower == "content-type" { hasContentType = true }
                lines.append("\(key): \(v)")
            }
            if !hasContentType { lines.append("Content-Type: application/json; charset=utf-8") }
            self.respond(connection, status: http.statusCode, headerLines: lines,
                         body: data ?? Data(), reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        task.resume()
    }

    // MARK: 响应

    private func respond(_ connection: NWConnection, status: Int,
                         headerLines: [String], body: Data, reason: String) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for line in headerLines { head += line + "\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Access-Control-Allow-Methods: GET,POST,PUT,DELETE,PATCH,OPTIONS\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - HTTP 请求解析

final class HTTPRequestParser {
    private(set) var method = ""
    private(set) var path = ""
    private(set) var headers: [String: String] = [:]
    private(set) var body = Data()
    private(set) var isComplete = false

    private var buffer = Data()
    private var headParsed = false
    private var chunked = false
    private var contentLength = 0
    private var chunkState = 0     // 0 读块长度行，1 读块数据，2 结束
    private var chunkRemaining = 0
    private var raw = Data()

    func append(_ data: Data) {
        buffer.append(data)
        if !headParsed { parseHead() }
        guard headParsed, !isComplete else { return }
        if chunked { parseChunked() } else { parseFixedLength() }
    }

    private func parseHead() {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        headParsed = true

        let lines = String(decoding: headData, as: UTF8.self).components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.components(separatedBy: " ")
            if parts.count >= 2 {
                method = parts[0]
                path = parts[1]
            }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var lowerKeys: [String: String] = [:]
        for (k, v) in headers { lowerKeys[k.lowercased()] = v }
        if let te = lowerKeys["transfer-encoding"], te.lowercased().contains("chunked") {
            chunked = true
        } else if let cl = lowerKeys["content-length"], let n = Int(cl) {
            contentLength = n
        }
        if !chunked && contentLength == 0 { isComplete = true }
    }

    private func parseFixedLength() {
        if buffer.count >= contentLength {
            body = Data(buffer.prefix(contentLength))
            isComplete = true
        }
    }

    private func parseChunked() {
        raw.append(buffer)
        buffer.removeAll()

        while true {
            if chunkState == 0 {
                guard let crlf = raw.range(of: Data("\r\n".utf8)) else { return }
                let lineData = raw.subdata(in: raw.startIndex..<crlf.lowerBound)
                raw.removeSubrange(raw.startIndex..<crlf.upperBound)
                let line = String(decoding: lineData, as: UTF8.self)
                let sizePart = line.components(separatedBy: ";").first ?? line
                let trimmed = sizePart.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let size = Int(trimmed, radix: 16) else {
                    chunkState = 2
                    isComplete = true
                    return
                }
                if size == 0 {
                    chunkState = 2
                    isComplete = true
                    return
                }
                chunkRemaining = size
                chunkState = 1
            }
            if chunkState == 1 {
                if raw.count >= chunkRemaining {
                    body.append(contentsOf: Array(raw.prefix(chunkRemaining)))
                    raw.removeSubrange(raw.startIndex..<(raw.startIndex + chunkRemaining))
                    chunkRemaining = 0
                    chunkState = 0
                } else {
                    return
                }
            }
            if chunkState == 2 { return }
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
