//
//  CKContainerInfo.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 25/07/2016.
//
//

import Foundation

struct CKContainerInfo {
    let environment: CKEnvironment
    let containerID: String
    
    func publicCloudDBURL(databaseScope: CKDatabaseScope) ->  URL {
        var baseURLPath = "\(CKServerInfo.path)/database/\(CKServerInfo.version)/\(containerID)/\(environment)"
        baseURLPath.append(contentsOf: "/\(databaseScope)")
        guard let url = URL(string: baseURLPath) else {
          fatalError("Failed to build URL from path: \(baseURLPath)")
        }
        return url
    }
    
    init(containerID: String, environment: CKEnvironment) {
        self.containerID = containerID
        self.environment = environment
    }
}
