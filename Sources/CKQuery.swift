//
//  CKQuery.swift
//  OpenCloudKit
//
//  Created by Benjamin Johnson on 6/07/2016.
//
//

import Foundation

struct CKQueryDictionary {
    static let recordType = "recordType"
    static let filterBy = "filterBy"
    static let sortBy = "sortBy"
}

struct CKSortDescriptorDictionary {
    static let fieldName = "fieldName"
    static let ascending = "ascending"
    static let relativeLocation = "relativeLocation"
}

public class CKQuery {
    
    public var recordType: String
    
    public var predicate: Predicate
    
    let filters: [CKFilter]
    
    public init(recordType: String, predicate: Predicate) {
        self.recordType = recordType
        self.predicate = predicate
        self.filters = CKPredicate(predicate: predicate).filters()
    }
    
    public init(recordType: String, filters: [CKFilter]) {
        self.recordType = recordType
        self.filters = filters
        self.predicate = Predicate(value: true)
    }
    
    public var sortDescriptors: [SortDescriptor] = []
    
    // Returns a Dictionary Representation of a Query Dictionary
    var dictionary: [String: AnyObject] {
        
        var queryDictionary: [String: AnyObject] = ["recordType": recordType.bridge()]
        
        queryDictionary["filterBy"] = filters.map({ (filter) -> [String: AnyObject] in
            return filter.dictionary
        }).bridge()
        
        // Create Sort Descriptor Dictionaries
        queryDictionary["sortBy"] = sortDescriptors.flatMap { (sortDescriptor) -> [String: AnyObject]? in
            
            if let fieldName = sortDescriptor.key {
                var sortDescriptionDictionary: [String: AnyObject] =  [CKSortDescriptorDictionary.fieldName: fieldName.bridge(),
                                                                       CKSortDescriptorDictionary.ascending: NSNumber(value: sortDescriptor.ascending)]
                if let locationSortDescriptor = sortDescriptor as? CKLocationSortDescriptor {
                    sortDescriptionDictionary[CKSortDescriptorDictionary.relativeLocation] = locationSortDescriptor.relativeLocation.recordFieldDictionary.bridge()
                }
                
                return sortDescriptionDictionary
               
            } else {
                return nil
            }
        }.bridge()
        
        return queryDictionary
    }
}
