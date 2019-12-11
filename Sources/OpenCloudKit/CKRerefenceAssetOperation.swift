//
//  CKFetchRecordsOperation.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 7/07/2016.
//
//

import Foundation

/// Operation which, after return, allows re-using an existing asset on a new CKRecord
//// See https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/RereferenceAssets.html#//apple_ref/doc/uid/TP40015240-CH9-SW1
public class CKRerefenceAssetOperation: CKDatabaseOperation {
  /*  This block is called when the operation completes.
   The [NSOperation completionBlock] will also be called if both are set.
   If the error is CKErrorPartialFailure, the error's userInfo dictionary contains
   a dictionary of recordIDs to errors keyed off of CKPartialErrorsByItemIDKey.
   */
  public var rereferenceAssetsCompletionBlock: (([CKAsset]?, Error?) -> Void)?

  /// Called for each asset
  /// this is the only way to receive per asset errors right now
  public var rereferenceAssetBlock: ((CKAsset?, Error?) -> Void)?

  /// Specified the record, from which an asset should be duplicated.
  public struct AssetRerefenceInfo: CustomDictionaryConvertible {
    var recordID: CKRecordID
    var recordFieldName: String

    public init(recordID: CKRecordID, recordFieldName: String) {
      self.recordID = recordID
      self.recordFieldName = recordFieldName
    }

    public var dictionary: [String : Any] {
      return [
        "recordName": recordID.recordName.bridge(),
        "fieldName": recordFieldName.bridge()
      ]
    }
  }

  public var zone: CKRecordZone
  public var referenceInfo: [AssetRerefenceInfo]
  public var fetchedAssets: [CKAsset]?

  public required init(existingRecords: [AssetRerefenceInfo], recordZone: CKRecordZone = .default()) {
    self.referenceInfo = existingRecords
    self.zone = recordZone
  }

  public override required init() {
    zone = .default()
    referenceInfo = [AssetRerefenceInfo]()
  }

  override func performCKOperation() {
    let url = "\(operationURL)/assets/\(CKAssetOperation.rereference)"

    var request: [String: Any] = [:]
    request["zoneID"] = zone.zoneID.dictionary.bridge()
    request["assets"] = referenceInfo.map { info in
      return info.dictionary.bridge()
    }.bridge()

    urlSessionTask = CKWebRequest(container: operationContainer).request(withURL: url, parameters: request) { [weak self] (dictionary, error) in
      guard let strongSelf = self, !strongSelf.isCancelled else { return }
      defer {
        strongSelf.finish(error: error)
      }

      guard let dictionary = dictionary,
        let assetsDictionary = dictionary["assets"] as? [[String: Any]],
        error == nil else {
          return
      }
      var fetchedAssets = [CKAsset]()
      for assetDictionary in assetsDictionary {
        guard let asset = CKAsset(dictionary: assetDictionary) else {
          let error = NSError(domain: CKErrorDomain,
                              code: CKErrorCode.PartialFailure.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse record from server".bridge()])
          strongSelf.rereferenceAssetBlock?(nil, error)
          continue
        }
        fetchedAssets.append(asset)
        strongSelf.rereferenceAssetBlock?(asset, nil)
      }
      strongSelf.fetchedAssets = fetchedAssets
    }
  }

  override func finishOnCallbackQueue(error: Error?) {
    rereferenceAssetsCompletionBlock?(fetchedAssets, error)

    super.finishOnCallbackQueue(error: error)
  }
}
