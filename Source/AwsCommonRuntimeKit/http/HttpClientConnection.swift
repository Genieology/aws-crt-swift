//  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//  SPDX-License-Identifier: Apache-2.0.

import AwsCHttp
import AwsCIo
import Foundation

public class HttpClientConnection {
    private let allocator: Allocator
    private let rawValue: UnsafeMutablePointer<aws_http_connection>
    
    init(connection: UnsafeMutablePointer<aws_http_connection>, allocator: Allocator = defaultAllocator) {
        self.allocator = allocator
        self.rawValue = connection
    }
    
    deinit {
        aws_http_connection_release(rawValue)
    }
    
    /// Creates an http connection to the host given via the `HttpClientConnectionOptions`
    /// - Parameters:
    ///   - options: An options object of type `HttpClientConnectionOptions` to send in all options for connectiing via http
    ///   - allocator: The allocator to use to allocate memory. If no allocator is passed in the `defaultAllocator` will be used.
    public static func createConnection(options: inout HttpClientConnectionOptions, allocator: Allocator = defaultAllocator) {
        let tempHostName = options.hostName.newByteCursor()
        
        var unmanagedConnectionOptions = aws_http_client_connection_options(
            self_size: 0,
            allocator: allocator.rawValue,
            bootstrap: options.clientBootstrap.rawValue,
            host_name: tempHostName.rawValue,
            port: options.port,
            socket_options: UnsafePointer(&options.socketOptions.rawValue),
            tls_options: nil,
            proxy_options: nil,
            monitoring_options: nil,
            manual_window_management: false,
            initial_window_size: options.initialWindowSize,
            user_data: nil,
            on_setup: { unmanagedConnection, errorCode, userData in
                guard let userData = userData else {
                    return
                }
                if let unmanagedConnection = unmanagedConnection,
                   errorCode == 0 {
                    let callbackData: HttpClientConnectionCallbackData = Unmanaged.fromOpaque(userData).takeRetainedValue()
                    callbackData.managedConnection = HttpClientConnection(connection: unmanagedConnection, allocator: callbackData.allocator)
                    callbackData.connectionOptions.onConnectionSetup(callbackData.managedConnection, errorCode)
                } else {
                    let callbackData: HttpClientConnectionCallbackData = Unmanaged.fromOpaque(userData).takeRetainedValue()
                    callbackData.connectionOptions.onConnectionSetup(nil, errorCode)
                }
            },
            on_shutdown: { _, errorCode, userData in
                guard let userData = userData else {
                    return
                }
                let callbackData: HttpClientConnectionCallbackData = Unmanaged.fromOpaque(userData).takeRetainedValue()
                
                callbackData.connectionOptions.onConnectionShutdown(callbackData.managedConnection, errorCode)
            },
            http1_options: nil,
            http2_options: nil
        )
        
        unmanagedConnectionOptions.self_size = MemoryLayout.size(ofValue: unmanagedConnectionOptions)
        
        if let tlsOptions = options.tlsOptions {
            unmanagedConnectionOptions.tls_options = UnsafePointer(tlsOptions.rawValue)
        }
        
        if var proxyOptions = options.proxyOptions {
            unmanagedConnectionOptions.proxy_options = UnsafePointer(&proxyOptions.rawValue)
        }
        
        let callbackData = HttpClientConnectionCallbackData(options: options, allocator: allocator)
        unmanagedConnectionOptions.user_data = Unmanaged.passRetained(callbackData).toOpaque()
        
        aws_http_client_connect(&unmanagedConnectionOptions)
    }
    
    public var isOpen: Bool {
        return aws_http_connection_is_open(self.rawValue)
    }
    
    /// Close the http connection
    public func close() {
        return aws_http_connection_close(self.rawValue)
    }
    
    /// Creates a new http stream from the `HttpRequestOptions` given.
    /// - Parameter requestOptions: An `HttpRequestOptions` struct containing callbacks on the different events from the stream
    /// - Returns: An `HttpStream` containing the `HttpClientConnection`
    public func newClientStream(requestOptions: HttpRequestOptions) -> HttpStream {
        var options = aws_http_make_request_options()
        options.self_size = MemoryLayout<aws_http_make_request_options>.size
        options.request = requestOptions.request.rawValue
        options.on_response_body = {_, data, userData -> Int32 in
            
            guard let userData = userData else {
                return -1
            }
            let httpStreamCbData: HttpStreamCallbackData = Unmanaged.fromOpaque(userData).takeUnretainedValue()
            guard let bufPtr = data!.pointee.ptr else {
                return -1
            }
            guard let bufLen = data?.pointee.len else {
                return -1
            }
            
            let callbackBytes = Data(bytesNoCopy: bufPtr, count: bufLen, deallocator: .none)
            httpStreamCbData.requestOptions.onIncomingBody!(httpStreamCbData.stream!, callbackBytes)
            
            return 0
        }
        options.on_response_headers = {_, headerBlock, headerArray, headersCount, userData -> Int32 in
            
            guard let userData = userData else {
                return -1
            }
            let httpStreamCbData: HttpStreamCallbackData = Unmanaged.fromOpaque(userData).takeUnretainedValue()
            
            var headers = [HttpHeader]()
            for cHeader in UnsafeBufferPointer(start: headerArray, count: headersCount) {
                if let name = cHeader.name.toString(),
                   let value = cHeader.value.toString() {
                    let swiftHeader = HttpHeader(name: name, value: value)
                    headers.append(swiftHeader)
                }
                
            }
            let headersStruct = HttpHeaders(fromArray: headers)
            httpStreamCbData.requestOptions.onIncomingHeaders(httpStreamCbData.stream!,
                                                              HttpHeaderBlock(rawValue: headerBlock),
                                                              headersStruct)
            return 0
        }
        options.on_response_header_block_done = {_, headerBlock, userData -> Int32 in
            
            guard let userData = userData else {
                return -1
            }
            let httpStreamCbData: HttpStreamCallbackData = Unmanaged.fromOpaque(userData).takeUnretainedValue()
            httpStreamCbData.requestOptions.onIncomingHeadersBlockDone(httpStreamCbData.stream!, HttpHeaderBlock(rawValue: headerBlock))
            return 0
        }
        options.on_complete = {_, errorCode, userData in
            
            guard let userData = userData else {
                return
            }
            let httpStreamCbData: HttpStreamCallbackData = Unmanaged.fromOpaque(userData).takeRetainedValue()
            httpStreamCbData.requestOptions.onStreamComplete!(httpStreamCbData.stream!, errorCode)
        }
        
        let cbData = HttpStreamCallbackData(requestOptions: requestOptions)
        options.user_data = Unmanaged.passRetained(cbData).toOpaque()
        
        let stream = HttpStream(httpConnection: self)
        cbData.stream = stream
        stream.httpStream = aws_http_connection_make_request(self.rawValue, &options)
        
        return stream
    }
    
}
