//
//  CKContainerConfig.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 14/07/2016.
//
//

import Foundation

enum CKConfigError: Error {
    case FailedInit
    case InvalidJSON
}

public struct CKConfig {
    
    let containers: [CKContainerConfig]
    
    public init(containers: [CKContainerConfig]) {
        self.containers = containers
    }
    
    public init(container: CKContainerConfig) {
        self.containers = [container]
    }
    
    init?(dictionary: [String: Any], workingDirectory: String?) {
        guard let containerDictionaries = dictionary["containers"] as? [[String: Any]] else {
            return nil
        }
        
        let containers = containerDictionaries.compactMap { (containerDictionary) -> CKContainerConfig? in
            var containerConfig = CKContainerConfig(dictionary: containerDictionary)
            if let workingDirectory = workingDirectory, let privateKeyFile = containerConfig?.serverToServerKeyAuth?.privateKeyFile {
                containerConfig?.serverToServerKeyAuth?.privateKeyFile = "\(workingDirectory)/\(privateKeyFile)"
            }
            return containerConfig
        }
        
        if containers.count > 0 {
            self.containers = containers
        } else {
            return nil
        }
    }
    
    public init(contentsOfFile path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        guard let jsonData = Data(base64Encoded: path, options: []),
          let dictionary = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            throw CKConfigError.InvalidJSON
        }
        self.init(dictionary: dictionary, workingDirectory: directory.path)!
    }
}

public struct CKContainerConfig {
    public let containerIdentifier: String
    public let environment: CKEnvironment
    public let apnsEnvironment: CKEnvironment
    public let apiTokenAuth: String?
    public var serverToServerKeyAuth: CKServerToServerKeyAuth?
    
    public init(containerIdentifier: String, environment: CKEnvironment,apiTokenAuth: String, apnsEnvironment: CKEnvironment? = nil) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        if let apnsEnvironment = apnsEnvironment {
            self.apnsEnvironment = apnsEnvironment
        } else {
            self.apnsEnvironment = environment
        }
        
        self.apiTokenAuth = apiTokenAuth
        self.serverToServerKeyAuth = nil
    }
    
    public init(containerIdentifier: String, environment: CKEnvironment, serverToServerKeyAuth: CKServerToServerKeyAuth, apnsEnvironment: CKEnvironment? = nil) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.apnsEnvironment = apnsEnvironment ?? environment
        self.apiTokenAuth = nil
        self.serverToServerKeyAuth = serverToServerKeyAuth
    }
    
    init?(dictionary: [String: Any]) {
        guard let containerIdentifier = dictionary["containerIdentifier"] as? String, let environmentValue = dictionary["environment"] as? String,
            let environment = CKEnvironment(rawValue: environmentValue)  else {
            return nil
        }
        
        let apnsEnvironment = CKEnvironment(rawValue: dictionary["apnsEnvironment"] as? String ?? "")
        
        if let apiTokenAuthDictionary = dictionary["apiTokenAuth"] as? [String: Any] {
            
            if let apiToken = apiTokenAuthDictionary["apiToken"] as? String {
                self.init(containerIdentifier: containerIdentifier, environment: environment, apiTokenAuth: apiToken, apnsEnvironment: apnsEnvironment)
            } else {
                return nil
            }
            
        } else if let serverToServerKeyAuthDictionary = dictionary["serverToServerKeyAuth"] as? [String: Any] {
            guard let keyID = serverToServerKeyAuthDictionary["keyID"] as? String, let privateKeyFile = serverToServerKeyAuthDictionary["privateKeyFile"] as? String else {
                return nil
            }
            
            let privateKeyPassPhrase = serverToServerKeyAuthDictionary["privateKeyPassPhrase"] as? String
            let auth = CKServerToServerKeyAuth(keyID: keyID, privateKeyFile: privateKeyFile, privateKeyPassPhrase: privateKeyPassPhrase)
            
            self.init(containerIdentifier: containerIdentifier, environment: environment, serverToServerKeyAuth: auth, apnsEnvironment: apnsEnvironment)

        } else {
            return nil
        }
    }
}

extension CKContainerConfig {
    var containerInfo: CKContainerInfo {
        return CKContainerInfo(containerID: containerIdentifier, environment: environment)
    }
}

public struct CKServerToServerKeyAuth {
    // A unique identifier for the key generated using CloudKit Dashboard. To create this key, read
    public let keyID: String
    // The path to the PEM encoded key file.
    public var privateKeyFile: String
    
    //The pass phrase for the key.
    public let privateKeyPassPhrase: String?
    
    public init(keyID: String, privateKeyFile: String, privateKeyPassPhrase: String? = nil) {
        self.keyID = keyID
        self.privateKeyFile = privateKeyFile
        self.privateKeyPassPhrase = privateKeyPassPhrase
    }
}
extension CKServerToServerKeyAuth:Equatable {}

public func ==(lhs: CKServerToServerKeyAuth, rhs: CKServerToServerKeyAuth) -> Bool {
    return lhs.keyID == rhs.keyID && lhs.privateKeyFile == rhs.privateKeyFile && lhs.privateKeyPassPhrase == rhs.privateKeyPassPhrase
}
