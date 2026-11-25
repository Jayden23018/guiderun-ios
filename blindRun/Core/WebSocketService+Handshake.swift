import Foundation

extension WebSocketService {
    /// 握手地址，**不带 token**。token 放请求头（`connectionRequest`）：查询串会进代理、负载均衡和 Nginx 日志。
    static func connectionURL(baseURL: URL, role: WSRole) -> URL? {
        var components = URLComponents()
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = role.path
        return components.url
    }

    /// 握手请求：`Authorization: Bearer <access token>`（后端 #881 / #1015）。
    /// 后端「有头只认头」：头无效就拒绝，不会回退去认查询串，所以这里**不许再同时带 `?token=`**。
    /// 首次连接和每次重连（含续期后重连）都走这一个入口，重连时用的是最新的 access。
    static func connectionRequest(baseURL: URL, token: String, role: WSRole) -> URLRequest? {
        guard let url = connectionURL(baseURL: baseURL, role: role) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
