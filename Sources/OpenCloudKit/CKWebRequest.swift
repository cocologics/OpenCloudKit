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

class CKWebRequest {

    var currentWebAuthToken: String?
    
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
    func uploadBinary(to url: URL, body: Data, completion: @escaping ([String: Any]?, Error?) -> Void) -> URLSessionTask? {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60
        // IMPORTANT: send the body via uploadTask(with:from:), NOT dataTask + httpBody.
        // On Linux (swift-corelibs-foundation) a large httpBody on a dataTask is not
        // streamed to the server even though a Content-Length header is sent, so the
        // server blocks waiting for a body that never arrives and the request times out
        // (NSURLErrorTimedOut / -1001). uploadTask streams the Data correctly and sets
        // Content-Length itself.

        CloudKit.debugPrint("[ocd-upload] POST \(url.absoluteString) bodyBytes=\(body.count)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)

        let task = session.uploadTask(with: urlRequest, from: body) { data, response, networkError in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodySnippet: String
            if let data = data {
                let s = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                bodySnippet = s.count > 500 ? String(s.prefix(500)) + "..." : s
            } else {
                bodySnippet = "<nil>"
            }
            CloudKit.debugPrint("[ocd-upload] response status=\(status) error=\(String(describing: networkError)) body=\(bodySnippet)")

            if let networkError = networkError {
                completion(nil, networkError)
                return
            }
            guard let data = data else {
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
        task.resume()
        return task
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
