import Logging
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol server
public actor Server {
    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// The server version
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the list of resources has changed
            public var list: Bool?
            /// Whether the resource can be read
            public var read: Bool?
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                list: Bool? = nil,
                read: Bool? = nil,
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.list = list
                self.read = read
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?

        public init(
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil
        ) {
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
        }
    }

    /// Server information
    private let serverInfo: Server.Info
    /// The server connection
    private var connection: (any Transport)?
    /// The server logger
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// The server capabilities
    public var capabilities = Capabilities()

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// The list of subscriptions
    private var subscriptions: [String: Set<ID>] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    public init(
        name: String,
        version: String,
        capabilities: Server.Capabilities = .init()
    ) {
        self.serverInfo = Server.Info(name: name, version: version)
        self.capabilities = capabilities
    }

    /// Start the server
    public func start(transport: any Transport) async throws {
        self.connection = transport
        registerDefaultHandlers()
        try await transport.connect()

        await logger?.info(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"])

        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await string in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        guard let data = string.data(using: .utf8) else {
                            throw Error.parseError("Invalid UTF-8 data")
                        }

                        // Attempt to decode string data as AnyRequest or AnyMessage
                        let decoder = JSONDecoder()
                        if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            try await handleRequest(request)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? JSONDecoder().decode(
                                [String: Value].self, from: data),
                                let idValue = json["id"]
                            {
                                if let strValue = idValue.stringValue {
                                    requestID = .string(strValue)
                                } else if let intValue = idValue.intValue {
                                    requestID = .number(intValue)
                                }
                            }
                            throw Error.parseError("Invalid message format")
                        }
                    } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                        // Resource temporarily unavailable, retry after a short delay
                        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                        continue
                    } catch {
                        await logger?.error(
                            "Error processing message", metadata: ["error": "\(error)"])
                        // Only send error responses for requests
                        if let requestID = requestID {
                            let mcpError =
                                error as? Error ?? Error.internalError(error.localizedDescription)
                            let response = AnyMethod.response(id: requestID, error: mcpError)
                            try? await send(response)
                        }
                    }
                }
            } catch {
                await logger?.error(
                    "Fatal error in message handling loop", metadata: ["error": "\(error)"])
            }
        }
    }

    /// Stop the server
    public func stop() async {
        task?.cancel()
        task = nil
        if let connection = connection {
            await connection.disconnect()
        }
        connection = nil
    }

    // MARK: - Registration

    /// Register a method handler
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>) -> Response<M> in
            let result = try await handler(request.params)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Sending

    /// Send a response to a client
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard let connection = connection else {
            throw Error.internalError("Server connection not initialized")
        }
        let responseData = try JSONEncoder().encode(response)
        if let responseStr = String(data: responseData, encoding: .utf8) {
            try await connection.send(responseStr)
        }
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw Error.internalError("Server connection not initialized")
        }
        let notificationData = try JSONEncoder().encode(notification)
        if let notificationStr = String(data: notificationData, encoding: .utf8) {
            try await connection.send(notificationStr)
        }
    }

    // MARK: -

    private func handleRequest(_ request: Request<AnyMethod>) async throws {
        await logger?.debug(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        // The client SHOULD NOT send requests other than pings
        // before the server has responded to the initialize request.
        switch request.method {
        case Initialize.name, Ping.name:
            break
        default:
            try checkInitialized()
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            let error = Error.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)
            try await send(response)
            throw error
        }

        do {
            // Handle request and get response
            let response = try await handler(request)
            try await send(response)
        } catch {
            let mcpError = error as? Error ?? Error.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            try await send(response)
            throw error
        }
    }

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
        await logger?.debug(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        // Check initialization state unless this is an initialized notification
        if message.method != InitializedNotification.name {
            try checkInitialized()
        }

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    private func checkInitialized() throws {
        guard isInitialized else {
            throw Error.invalidRequest("Server is not initialized")
        }
    }

    private func registerDefaultHandlers() {
        // Initialize
        withMethodHandler(Initialize.self) { [weak self] params in
            guard let self = self else {
                throw Error.internalError("Server was deallocated")
            }

            guard await !self.isInitialized else {
                throw Error.invalidRequest("Server is already initialized")
            }

            // Validate protocol version
            guard Version.latest == params.protocolVersion else {
                throw Error.invalidRequest(
                    "Unsupported protocol version: \(params.protocolVersion)")
            }

            await self.setInitialState(
                clientInfo: params.clientInfo,
                clientCapabilities: params.capabilities,
                protocolVersion: params.protocolVersion
            )

            let result = Initialize.Result(
                protocolVersion: Version.latest,
                capabilities: await self.capabilities,
                serverInfo: self.serverInfo,
                instructions: nil
            )

            // Send initialized notification after a short delay
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                try? await self.notify(InitializedNotification.message())
            }

            return result
        }

        // Ping
        withMethodHandler(Ping.self) { _ in return Empty() }
    }

    private func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
        self.isInitialized = true
    }
}
