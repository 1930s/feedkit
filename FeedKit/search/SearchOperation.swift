//
//  SearchOperation.swift
//  FeedKit
//
//  Created by Michael Nisi on 15.01.18.
//  Copyright © 2018 Michael Nisi. All rights reserved.
//

import Foundation
import os.log

/// An operation for searching feeds and entries.
final class SearchOperation: SearchRepoOperation {
  
  var perFindGroupBlock: ((Error?, [Find]) -> Void)?
  
  var searchCompletionBlock: ((Error?) -> Void)?
  
  /// `FeedKitError.cancelledByUser` overrides passed errors.
  fileprivate func done(_ error: Error? = nil) {
    let er = isCancelled ? FeedKitError.cancelledByUser : error
    searchCompletionBlock?(er)
    
    perFindGroupBlock = nil
    searchCompletionBlock = nil
    isFinished = true
  }
  
  /// Remotely request search and subsequently update the cache while falling
  /// back on stale feeds in stock. Finally, end the operation after applying
  /// the callback. Passing empty stock makes no sense.
  ///
  /// - Parameter stock: Stock of stale feeds to fall back on.
  fileprivate func request(_ stock: [Feed]? = nil) throws {
    os_log("requesting: %@", log: Search.log, type: .debug, term)
    
    // Capturing self as unowned to crash when we've mistakenly ended the
    // operation, here or somewhere else, inducing the system to release it.
    task = try svc.search(term: term) { [unowned self] payload, error in
      self.post(name: Notification.Name.FKRemoteResponse)
      
      var er: Error?
      defer {
        self.done(er)
      }
      
      guard !self.isCancelled else {
        return
      }
      
      guard error == nil else {
        er = FeedKitError.serviceUnavailable(error: error!)
        if let cb = self.perFindGroupBlock {
          if let feeds = stock {
            guard !feeds.isEmpty else { return }
            let finds = feeds.map { Find.foundFeed($0) }
            cb(nil, finds)
          }
        }
        return
      }
      
      guard payload != nil else {
        return
      }
      
      do {
        let (errors, feeds) = serialize.feeds(from: payload!)
        
        if !errors.isEmpty {
          os_log("JSON parse errors: %{public}@", log: Search.log,  type: .error, errors)
        }
        
        try self.cache.update(feeds: feeds, for: self.term)
        
        let now = Date()
        
        guard
          !feeds.isEmpty,
          let cb = self.perFindGroupBlock,
          // Rereading from the cache takes below 3 milliseconds.
          let cached = try self.cache.feeds(for: self.term, limit: 25) else {
          return
        }
        
        let diff = Date().timeIntervalSince(now)

        os_log("rereading from the cache took: %{public}@",
               log: Search.log, type: .debug, String(describing: diff))
        
        let finds = cached.map { Find.foundFeed($0) }
        
        guard !self.isCancelled else {
          return
        }
        
        cb(nil, finds)
      } catch {
        er = error
      }
    }
  }

  private var fetchingFeeds: FeedsOperation? {
    for dep in dependencies {
      if let op = dep as? FeedsOperation {
        return op
      }
    }
    return nil
  }

  override func start() {
    guard !isCancelled else {
      return done()
    }
    
    guard !term.isEmpty else {
      return done(FeedKitError.invalidSearchTerm(term: term))
    }
    
    isExecuting = true
    
    if let op = fetchingFeeds {
      guard op.error == nil else {
        return done(op.error)
      }
      
      guard let feed = op.feeds.first else {
        return done()
      }
      
      let find = Find.foundFeed(feed)
      perFindGroupBlock?(nil, [find])
      return done()
    }
    
    do {
      guard let cached = try cache.feeds(for: term, limit: 25) else {
        return try request()
      }
      
      os_log("cached: %{public}@", log: Search.log, type: .debug, cached)
      
      if isCancelled { return done() }
      
      // If we match instead of equal, to yield more interesting results, we
      // cannot determine the age of a cached search because we might have
      // multiple differing timestamps. Using the median timestamp to determine
      // age works for both: equaling and matching.
      
      guard let ts = FeedCache.medianTS(cached) else {
        return done()
      }
      
      let shouldRefresh = FeedCache.stale(ts, ttl: CacheTTL.long.seconds)
      
      if shouldRefresh {
        try request(cached)
      } else {
        guard let cb = perFindGroupBlock else {
          return done()
        }
        let finds = cached.map { Find.foundFeed($0) }
        cb(nil, finds)
        return done()
      }
    } catch {
      done(error)
    }
  }
}
