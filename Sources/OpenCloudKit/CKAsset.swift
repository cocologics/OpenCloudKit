//
//  CKAsset.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 16/07/2016.
//
//

import Foundation

public class CKAsset: NSObject {
    
    public var fileURL : URL
    
    var recordKey: String?
    var fileChecksum: String?
    var uploaded: Bool = false
    
    var downloaded: Bool = false
    
    var recordID: CKRecordID?
    
    var downloadBaseURL: String?
        
    var downloadURL: URL? {
        get {
            if let downloadBaseURL = downloadBaseURL {
                return URL(string: downloadBaseURL)!
            } else {
                return nil
            }
        }
    }
    
    var size: UInt?
    
    var hasSize: Bool {
        return size != nil
    }
    
    var uploadReceipt: String?
    
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
    
    init?(dictionary: [String: Any]) {
        guard let size = dictionary["size"] as? NSNumber else {
            return nil
        }
      if let downloadURL = dictionary["downloadURL"] as? String {
        let downloadURLString = downloadURL.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)!

        fileURL = URL(string: downloadURLString)!
        self.downloadBaseURL = downloadURL
      } else {
        // TODO: this does not work as expected
        fileURL = URL(fileURLWithPath: "")
      }
      self.size = size.uintValue
      self.fileChecksum = dictionary["fileChecksum"] as? String
      self.uploadReceipt = dictionary["receipt"] as? String
      downloaded = false
    }
}

extension CKAsset: CustomDictionaryConvertible {
    public var dictionary: [String: Any] {
        var fieldDictionary: [String: Any] = [:]
        if let recordID = recordID, let recordKey = recordKey {
            fieldDictionary["recordName"] = recordID.recordName.bridge()
        //    fieldDictionary["recordType"] = "Items".bridge()
            fieldDictionary["fieldName"] = recordKey.bridge()
        }
        fieldDictionary["fileChecksum"] = fileChecksum?.bridge()
        fieldDictionary["size"] = size?.bridge()
        fieldDictionary["receipt"] = uploadReceipt?.bridge()
        return fieldDictionary
    }
}
