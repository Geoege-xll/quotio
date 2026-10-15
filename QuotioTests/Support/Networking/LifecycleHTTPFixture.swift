import Foundation

/// 可显式释放的离线响应，用于稳定复现旧列表／旧会话在新操作之后才返回的次序。
/// 锁只交换回调与结果，真正的 URLProtocol 回调在锁外执行；先释放再注册也不会丢失响应。
final class LifecycleHTTPResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: LifecycleHTTPState.Response?
    private var completion: ((LifecycleHTTPState.Response) -> Void)?

    func receive(_ completion: @escaping (LifecycleHTTPState.Response) -> Void) {
        let ready: LifecycleHTTPState.Response? = lock.withLock { () -> LifecycleHTTPState.Response? in
            if let result { return result }
            self.completion = completion
            return nil
        }
        if let ready { completion(ready) }
    }

    func release(_ result: LifecycleHTTPState.Response) {
        let completion = lock.withLock {
            self.result = result
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?(result)
    }
}

/// 跨模块测试共用的离线 HTTP 夹具，集中在测试 Support 中，避免依赖某个测试类所在目录。
/// 保持原有类型名称与内部访问级别；每个用例负责注册和移除自己的随机主机状态，
/// 只截获注入 URLProtocol 的测试会话，不参与应用运行或连接真实 CPA。
/// 每个测试使用独立主机名和状态，锁只保护 URLProtocol 的跨线程回调记录。
final class LifecycleHTTPState: @unchecked Sendable {
    enum Response { case reply(String), replyStatus(String, Int), fail(URLError.Code), redirect(String), hold, deferred(LifecycleHTTPResponseGate) }
    private let lock = NSLock()
    private var count = 0
    /// 记录实际 URLSession 请求的契约，正文在流还可读时复制，供独立 v8 契约用例检查。
    struct Record: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let contentType: String?
        let body: Data?
    }
    private var records: [Record] = []
    private let response: @Sendable (URLRequest, Int) -> Response
    init(response: @escaping @Sendable (URLRequest, Int) -> Response) { self.response = response }
    var requestCount: Int { lock.withLock { count } }
    var requests: [Record] { lock.withLock { records } }
    func next(_ request: URLRequest) -> Response {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while true {
                let length = stream.read(&bytes, maxLength: bytes.count)
                if length <= 0 { break }
                data.append(contentsOf: bytes.prefix(length))
            }
            body = data
        }
        let record = Record(url: request.url!, method: request.httpMethod ?? "GET",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body)
        let count = lock.withLock { self.count += 1; records.append(record); return self.count }
        return response(request, count)
    }
}

final class LifecycleHTTPProtocol: URLProtocol, @unchecked Sendable {
    private let responseLock = NSLock()
    private var stopped = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: LifecycleHTTPState] = [:]
    static func register(_ state: LifecycleHTTPState, host: String) { lock.withLock { states[host] = state } }
    static func remove(host: String) { lock.withLock { _ = states.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.lock.withLock({ Self.states[request.url!.host!] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        respond(state.next(request))
    }

    private func respond(_ response: LifecycleHTTPState.Response) {
        guard responseLock.withLock({ !stopped }) else { return }
        switch response {
        case .reply(let body), .replyStatus(let body, 200):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .replyStatus(let body, let status):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let destination):
            var redirected = request
            redirected.url = URL(string: destination)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302,
                httpVersion: nil, headerFields: ["Location": destination])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        case .hold:
            break
        case .deferred(let gate):
            gate.receive { [weak self] response in self?.respond(response) }
        }
    }
    override func stopLoading() { responseLock.withLock { stopped = true } }
}
