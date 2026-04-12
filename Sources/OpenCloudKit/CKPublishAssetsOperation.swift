//
//  CKPublishAssetsOperation.swift
//  OpenCloudKit
//
//  Originally created by Benjamin Johnson on 16/07/2016 as an empty stub.
//  Reimplemented to support uploading new CKAsset binaries via the
//  CloudKit Web Services /assets/upload endpoint.
//

import Foundation

#if os(Linux)
import FoundationNetworking
#endif

/// Uploads new CKAsset binaries prior to a `records/modify` call.
///
/// CKAssets that hold a local `fileURL` need their contents uploaded to CloudKit
/// before the owning record can be saved. This operation performs the two-step
/// CKWS flow: request upload URLs via `/assets/upload`, then POST each binary
/// and capture `fileChecksum`, `receipt`, and `size` back onto the asset.
public class CKPublishAssetsOperation: CKDatabaseOperation {

    /// An asset paired with the record it is being saved on.
    public struct PendingAsset {
        public let asset: CKAsset
        public let recordType: String
        public let recordName: String
        public let fieldName: String

        public init(asset: CKAsset, recordType: String, recordName: String, fieldName: String) {
            self.asset = asset
            self.recordType = recordType
            self.recordName = recordName
            self.fieldName = fieldName
        }
    }

    public var pendingAssets: [PendingAsset]
    public var zoneID: CKRecordZoneID?

    /// Called for each asset individually.
    public var assetPublishedBlock: ((CKAsset?, Error?) -> Void)?

    /// Called when the entire publish operation completes.
    public var publishAssetsCompletionBlock: (([CKAsset]?, Error?) -> Void)?

    private var publishedAssets: [CKAsset] = []

    public init(pendingAssets: [PendingAsset], zoneID: CKRecordZoneID? = nil) {
        self.pendingAssets = pendingAssets
        self.zoneID = zoneID
        super.init()
    }

    public override required init() {
        self.pendingAssets = []
        super.init()
    }

    override func finishOnCallbackQueue(error: Error?) {
        CloudKit.debugPrint("[ocd-publish] finishing with error=\(String(describing: error))")
        publishAssetsCompletionBlock?(publishedAssets, error)
        publishAssetsCompletionBlock = nil
        assetPublishedBlock = nil
        super.finishOnCallbackQueue(error: error)
    }

    override func performCKOperation() {
        CloudKit.debugPrint("[ocd-publish] performCKOperation with \(pendingAssets.count) pending assets")
        guard !pendingAssets.isEmpty else {
            finish(error: nil)
            return
        }

        let url = "\(operationURL)/assets/\(CKAssetOperation.upload.rawValue)"
        CloudKit.debugPrint("[ocd-publish] POST \(url)")

        var request: [String: Any] = [:]
        if let zoneID = zoneID {
            request["zoneID"] = zoneID.dictionary.bridge()
        }
        request["tokens"] = pendingAssets.map { pending -> NSDictionary in
            let token: [String: Any] = [
                "recordType": pending.recordType.bridge(),
                "recordName": pending.recordName.bridge(),
                "fieldName": pending.fieldName.bridge(),
            ]
            return token.bridge() as NSDictionary
        }.bridge()

        let webRequest = CKWebRequest(container: operationContainer)
        urlSessionTask = webRequest.request(withURL: url, parameters: request) { [weak self] (dictionary, error) in
            guard let strongSelf = self, !strongSelf.isCancelled else { return }
            CloudKit.debugPrint("[ocd-publish] /assets/upload response error=\(String(describing: error)) dict=\(String(describing: dictionary))")

            if let error = error {
                strongSelf.finish(error: error)
                return
            }
            guard let dictionary = dictionary,
                  let tokens = dictionary["tokens"] as? [[String: Any]] else {
                strongSelf.finish(error: NSError(domain: CKErrorDomain,
                                                 code: CKErrorCode.InternalError.rawValue,
                                                 userInfo: [NSLocalizedDescriptionKey: "Missing tokens in /assets/upload response"]))
                return
            }
            guard tokens.count == strongSelf.pendingAssets.count else {
                strongSelf.finish(error: NSError(domain: CKErrorDomain,
                                                 code: CKErrorCode.InternalError.rawValue,
                                                 userInfo: [NSLocalizedDescriptionKey: "Token count \(tokens.count) does not match pending asset count \(strongSelf.pendingAssets.count)"]))
                return
            }
            strongSelf.uploadBinaries(webRequest: webRequest, tokens: tokens)
        }
    }

    private func uploadBinaries(webRequest: CKWebRequest, tokens: [[String: Any]]) {
        let group = DispatchGroup()
        var firstError: Error?
        let errorLock = NSLock()

        for (pending, token) in zip(pendingAssets, tokens) {
            guard let urlString = token["url"] as? String, let uploadURL = URL(string: urlString) else {
                errorLock.lock()
                if firstError == nil {
                    firstError = NSError(domain: CKErrorDomain,
                                         code: CKErrorCode.InternalError.rawValue,
                                         userInfo: [NSLocalizedDescriptionKey: "Missing upload url for field \(pending.fieldName)"])
                }
                errorLock.unlock()
                callbackQueue.async { self.assetPublishedBlock?(pending.asset, firstError) }
                continue
            }

            let body: Data
            do {
                body = try Data(contentsOf: pending.asset.fileURL)
            } catch {
                errorLock.lock()
                if firstError == nil { firstError = error }
                errorLock.unlock()
                callbackQueue.async { self.assetPublishedBlock?(pending.asset, error) }
                continue
            }

            group.enter()
            _ = webRequest.uploadBinary(to: uploadURL, body: body) { [weak self] (response, uploadError) in
                defer { group.leave() }
                guard let strongSelf = self else { return }

                if let uploadError = uploadError {
                    errorLock.lock()
                    if firstError == nil { firstError = uploadError }
                    errorLock.unlock()
                    strongSelf.callbackQueue.async { strongSelf.assetPublishedBlock?(pending.asset, uploadError) }
                    return
                }

                // Response may be flat or nested under "singleFile".
                let fields = (response?["singleFile"] as? [String: Any]) ?? response
                guard let fields = fields else {
                    let err = NSError(domain: CKErrorDomain,
                                      code: CKErrorCode.InternalError.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "Empty asset upload response"])
                    errorLock.lock()
                    if firstError == nil { firstError = err }
                    errorLock.unlock()
                    strongSelf.callbackQueue.async { strongSelf.assetPublishedBlock?(pending.asset, err) }
                    return
                }
                guard let checksum = fields["fileChecksum"] as? String,
                      let receipt = fields["receipt"] as? String,
                      let size = (fields["size"] as? NSNumber)?.uintValue ?? UInt(exactly: (fields["size"] as? Int) ?? -1) else {
                    let err = NSError(domain: CKErrorDomain,
                                      code: CKErrorCode.InternalError.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "Asset upload response missing required fields: \(fields)"])
                    errorLock.lock()
                    if firstError == nil { firstError = err }
                    errorLock.unlock()
                    strongSelf.callbackQueue.async { strongSelf.assetPublishedBlock?(pending.asset, err) }
                    return
                }

                pending.asset.fileChecksum = checksum
                pending.asset.uploadReceipt = receipt
                pending.asset.size = size
                pending.asset.uploaded = true

                strongSelf.callbackQueue.async {
                    strongSelf.publishedAssets.append(pending.asset)
                    strongSelf.assetPublishedBlock?(pending.asset, nil)
                }
            }
        }

        group.notify(queue: callbackQueue) { [weak self] in
            self?.finish(error: firstError)
        }
    }
}
