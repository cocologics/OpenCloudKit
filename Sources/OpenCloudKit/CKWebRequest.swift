//
//  CKWebRequest.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 6/07/2016.
//
//

import Foundation

#if os(Linux)
import FoundationNetworking
#endif

import AsyncHTTPClient
import NIOCore
import NIOHTTP1

class CKWebRequest {

    var currentWebAuthToken: String?

    /// Process-lifetime HTTP client used *only* for the binary CKAsset upload to
    /// the pre-signed cws.icloud-content.com URL. AsyncHTTPClient is NIO-based and
    /// honors HTTP/2 flow-control (WINDOW_UPDATE) correctly, unlike Foundation's
    /// URLSession on Linux which stalls uploads past the ~64 KB initial window.
    /// A single shared client avoids spinning up (and leaking) an EventLoopGroup
    /// per call; it lives for the lifetime of the process and is never shut down.
    private static let assetUploadHTTPClient = HTTPClient(eventLoopGroupProvider: .createNew)
    
    let containerConfig: CKContainerConfig
    
    init(containerConfig: CKContainerConfig) {
        self.containerConfig = containerConfig
    }
    
    convenience init(container: CKContainer) {
        self.init(containerConfig: CloudKit.shared.containerConfig(forContainer: container)!)
    }
    
    var authQueryItems: [URLQueryItem]? {
        
        if let apiTokenAuth = containerConfig.apiTokenAuth {
            var queryItems: [URLQueryItem] = []

            let apiTokenQueryItem = URLQueryItem(name: "ckAPIToken", value: apiTokenAuth)
            queryItems.append(apiTokenQueryItem)
            
            
            if let currentWebAuthToken = currentWebAuthToken {
                let webAuthTokenQueryItem = URLQueryItem(name: "ckWebAuthToken", value: currentWebAuthToken)
                queryItems.append(webAuthTokenQueryItem)
            }
            
            return queryItems
        } else {
            return nil
        }
    }
    
    var serverToServerKeyAuth: CKServerToServerKeyAuth? {
        return containerConfig.serverToServerKeyAuth
    }
    /*
    func ckError(forNetworkError networkError: Error) -> NSError {
        
        let networkError = networkError as NSError
        let userInfo = networkError.userInfo
        let errorCode: CKErrorCode
        
        switch networkError.code {
        case NSURLErrorNotConnectedToInternet:
            errorCode = .NetworkUnavailable
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            errorCode = .ServiceUnavailable
        default:
            errorCode = .NetworkFailure
        }
        
        let error = NSError(domain: CKErrorDomain, code: errorCode.rawValue, userInfo: userInfo)
        return error
    }
    */
    func ckError(forServerResponseDictionary dictionary: [String: Any]) -> NSError {
        if let recordFetchError = CKRecordFetchErrorDictionary(dictionary: dictionary) {
            
            let errorCode = CKErrorCode.errorCode(serverError: recordFetchError.serverErrorCode)!
            
            var userInfo: NSErrorUserInfoType  = [:]
         
            userInfo["redirectURL"] = recordFetchError.redirectURL
            userInfo[NSLocalizedDescriptionKey] = recordFetchError.reason
            
            userInfo[CKErrorRetryAfterKey] = recordFetchError.retryAfter
            userInfo["uuid"] = recordFetchError.uuid

            return NSError(domain: CKErrorDomain, code: errorCode.rawValue, userInfo: userInfo)
            
        } else {
            
           
            return NSError(domain: CKErrorDomain, code: CKErrorCode.InternalError.rawValue, userInfo: NSErrorUserInfoType())
        }
    }

    func perform(request: URLRequest, completionHandler: @escaping ([String: Any]?, Error?) -> Void) -> URLSessionTask? {
        
        let session = URLSession.shared
       
        let requestCompletionHandler:  (Data?, URLResponse?, Error?) -> Swift.Void = { (data, response, networkError) in
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodySnippet: String
            if let data = data {
                let s = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                bodySnippet = s.count > 500 ? String(s.prefix(500)) + "..." : s
            } else {
                bodySnippet = "<nil>"
            }
            CloudKit.debugPrint("[ocd-web] \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?") → status=\(httpStatus) error=\(String(describing: networkError)) body=\(bodySnippet)")

            if let networkError = networkError {
                completionHandler(nil, networkError)
                return
            }
            guard let data = data else {
                completionHandler(nil, NSError(domain: CKErrorDomain, code: CKErrorCode.InternalError.rawValue, userInfo: [NSLocalizedDescriptionKey: "No data and no error in CKWebRequest response (status \(httpStatus))"]))
                return
            }
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = jsonObject as? [String: Any] else {
                completionHandler(nil, NSError(domain: CKErrorDomain, code: CKErrorCode.InternalError.rawValue, userInfo: [NSLocalizedDescriptionKey: "Response not JSON (status \(httpStatus)): \(bodySnippet)"]))
                return
            }
            if httpStatus >= 400 {
                completionHandler(nil, self.ckError(forServerResponseDictionary: dictionary))
            } else {
                completionHandler(dictionary, nil)
            }
        }
        let task = session.dataTask(with: request, completionHandler: requestCompletionHandler)
        
        task.resume()
        
        return task
    }
    
    func urlRequest(with url: URL, parameters: [String: Any]? = nil) -> URLRequest? {
        // Build URL
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
       
        components?.queryItems = authQueryItems
        CloudKit.debugPrint(components?.path as Any)
        guard let requestURL = components?.url else {
            return nil
        }
        
        var urlRequest = URLRequest(url: requestURL)
        if let parameters = parameters {
            
            #if os(Linux)
                let jsonData: Data = try! JSONSerialization.data(withJSONObject: parameters.bridge(), options: [])
            #else
                let jsonData: Data = try! JSONSerialization.data(withJSONObject: parameters, options: [])
            #endif
            
            urlRequest.httpBody = jsonData
            urlRequest.httpMethod = "POST"
        } else {
            let jsonData: Data = try! JSONSerialization.data(withJSONObject: NSDictionary(), options: [])
            urlRequest.httpBody = jsonData
            urlRequest.httpMethod = "GET"
        }
        
        if let serverToServerKeyAuth = serverToServerKeyAuth {
            if let signedRequest  = CKServerRequestAuth.authenticateServer(forRequest: urlRequest, withServerToServerKeyAuth: serverToServerKeyAuth) {
                urlRequest = signedRequest
            }
        }
        
        return urlRequest
    }

    
    func request(withURL url: String, completetion: @escaping ([String: Any]?, Error?) -> Void) -> URLSessionTask? {
       
        // Build URL
        var components = URLComponents(string: url)
        components?.queryItems = authQueryItems
        CloudKit.debugPrint(components?.path as Any)
        guard let requestURL = components?.url else {
            return nil
        }
        
        let jsonData: Data = try! JSONSerialization.data(withJSONObject: NSDictionary(), options: [])
        var urlRequest = URLRequest(url: requestURL)
        
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = jsonData
        
        return perform(request: urlRequest, completionHandler: completetion)
    }
    
    
    /// Upload raw binary to a pre-signed CloudKit asset-upload URL.
    /// The URL already carries signature query params, so we do NOT run it through CKServerRequestAuth.
    ///
    /// Uses AsyncHTTPClient (NIO) rather than Foundation's URLSession: on Linux
    /// (swift-corelibs-foundation) URLSession does not honor HTTP/2 WINDOW_UPDATE,
    /// so uploads to the HTTP/2 host cws.icloud-content.com stall right around the
    /// 64 KB initial flow-control window and time out (NSURLErrorDomain -1001).
    /// AsyncHTTPClient handles HTTP/2 flow control correctly. The completion-handler
    /// signature is unchanged; the return value is unused by callers (kept for
    /// source compatibility), so we return nil.
    @discardableResult
    func uploadBinary(to url: URL, body: Data, completion: @escaping ([String: Any]?, Error?) -> Void) -> URLSessionTask? {
        CloudKit.debugPrint("[ocd-upload] POST \(url.absoluteString) bodyBytes=\(body.count)")

        do {
            var request = try HTTPClient.Request(url: url.absoluteString, method: .POST)
            request.headers.add(name: "Content-Type", value: "application/octet-stream")
            // .bytes sets Content-Length from the byte count and streams the body
            // honoring HTTP/2 flow control.
            request.body = .bytes(body)

            CKWebRequest.assetUploadHTTPClient
                .execute(request: request, deadline: .now() + .seconds(120))
                .whenComplete { result in
                    switch result {
                    case .failure(let networkError):
                        CloudKit.debugPrint("[ocd-upload] response error=\(networkError)")
                        completion(nil, networkError)

                    case .success(let response):
                        let status = Int(response.status.code)
                        let data: Data
                        if let buffer = response.body, buffer.readableBytes > 0 {
                            data = Data(buffer.readableBytesView)
                        } else {
                            data = Data()
                        }
                        let bodySnippet: String = {
                            let s = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                            return s.count > 500 ? String(s.prefix(500)) + "..." : s
                        }()
                        CloudKit.debugPrint("[ocd-upload] response status=\(status) body=\(bodySnippet)")

                        guard !data.isEmpty else {
                            completion(nil, NSError(domain: CKErrorDomain, code: CKErrorCode.InternalError.rawValue, userInfo: [NSLocalizedDescriptionKey: "No data in asset upload response (status \(status))"]))
                            return
                        }
                        let object = try? JSONSerialization.jsonObject(with: data, options: [])
                        guard let dictionary = object as? [String: Any] else {
                            completion(nil, NSError(domain: CKErrorDomain, code: CKErrorCode.InternalError.rawValue, userInfo: [NSLocalizedDescriptionKey: "Asset upload response not JSON (status \(status)): \(bodySnippet)"]))
                            return
                        }
                        if status >= 400 {
                            completion(nil, self.ckError(forServerResponseDictionary: dictionary))
                            return
                        }
                        completion(dictionary, nil)
                    }
                }
        } catch {
            CloudKit.debugPrint("[ocd-upload] request build error=\(error)")
            completion(nil, error)
        }

        return nil
    }

    func request(withURL url: String, parameters: [String: Any]?, completetion: @escaping ([String: Any]?, Error?) -> Void) -> URLSessionTask? {
        
        // Build URL
        var components = URLComponents(string: url)
        components?.queryItems = authQueryItems
        CloudKit.debugPrint(components?.path as Any)
        guard let requestURL = components?.url else {
            return nil
        }
        
        var urlRequest = URLRequest(url: requestURL)
        if let parameters = parameters {
            
            #if os(Linux)
            let jsonData: Data = try! JSONSerialization.data(withJSONObject: parameters.bridge(), options: [])
            #else
            let jsonData: Data = try! JSONSerialization.data(withJSONObject: parameters, options: [])
            #endif
            
            urlRequest.httpBody = jsonData
            urlRequest.httpMethod = "POST"
        } else {
            let jsonData: Data = try! JSONSerialization.data(withJSONObject: NSDictionary(), options: [])
            urlRequest.httpBody = jsonData
            urlRequest.httpMethod = "GET"
        }
        
        urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        if let serverToServerKeyAuth = serverToServerKeyAuth {
            if let signedRequest  = CKServerRequestAuth.authenticateServer(forRequest: urlRequest, withServerToServerKeyAuth: serverToServerKeyAuth) {
                urlRequest = signedRequest
            }
        }
        
        return perform(request: urlRequest, completionHandler: completetion)
    }
    
    
    
}
