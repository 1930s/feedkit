//
//  user.swift
//  FeedKit
//
//  Created by Michael Nisi on 31/01/16.
//  Copyright © 2016 Michael Nisi. All rights reserved.
//

import Foundation
import Skull
import os.log

public class UserCache: LocalCache {}

@available(iOS 10.0, *)
fileprivate let log = OSLog(subsystem: "ink.codes.feedkit", category: "user")

extension UserCache: QueueCaching {
  
  public func _queued(sql: String) throws -> [Queued] {
    var er: Error?
    var locators = [Queued]()
    
    let fmt = self.sqlFormatter
    
    queue.sync {
      do {
        try db.query(sql) { skullError, row -> Int in
          guard skullError == nil else {
            er = skullError
            return 1
          }
          guard let r = row else {
            return 0
          }
          let locator = fmt.queuedLocator(from: r)
          locators.append(locator)
          return 0
        }
      } catch {
        er = error
      }
    }
    
    if let error = er {
      throw error
    }
    
    return locators
  }
  
  /// The user‘s queued entries, sorted by time queued.
  public func queued() throws -> [Queued] {
    return try _queued(sql: SQLFormatter.SQLToSelectAllQueued)
  }
  
  public func local() throws -> [Queued] {
    return try _queued(sql: SQLFormatter.SQLToSelectLocallyQueuedEntries)
  }
  
  public func remove(guids: [String]) throws {
    var er: Error?
    
    queue.sync {
      guard let sql = SQLFormatter.SQLToUnqueue(guids: guids) else {
        return
      }
      do {
        try db.exec(sql)
      } catch {
        er = error
      }
    }
    
    if let error = er {
      throw error
    }
  }
  
  public func remove(recordNames: [String]) throws {
    var er: Error?
    
    queue.sync {
      guard let sql = SQLFormatter.SQLToDeleteRecords(with: recordNames) else {
        return
      }
      do {
        try db.exec(sql)
      } catch {
        er = error
      }
    }
    
    if let error = er {
      throw error
    }
  }
  
  public func add(_ entries: [EntryLocator]) throws {
    var er: Error?
    
    let fmt = self.sqlFormatter
    
    queue.sync {
      do {
        let sql = entries.reduce([String]()) { acc, loc in
          guard er == nil else {
            return acc
          }
          guard let guid = loc.guid else {
            er = FeedKitError.invalidEntry(reason: "missing guid")
            return acc
          }
          let sql = fmt.SQLToQueue(entry: loc, with: guid)
          return acc + [sql]
        }.joined(separator: "\n")
        
        try db.exec(sql)
      } catch {
        er = error
      }
    }
    
    if let error = er {
      throw error
    }
  }
  
  public func add(synced: [Synced]) throws {
    var er: Error?
    
    let fmt = self.sqlFormatter
    
    queue.sync {
      do {
        let sql = synced.reduce([String]()) { acc, loc in
          let sql = fmt.SQLToQueueSynced(locator: loc)
          return acc + [sql]
        }.joined(separator: "\n")
        
        try db.exec(["BEGIN;", sql, "COMMIT;"].joined(separator: "\n"))
      } catch {
        er = error
      }
    }
    
    if let error = er {
      throw error
    }
  }
  
}

private final class FetchQueueOperation: FeedKitOperation {
  
  var sortOrderBlock: (([String]) -> Void)?
  var entriesBlock: ((Error?, [Entry]) -> Void)?
  var entriesCompletionBlock: ((Error?) -> Void)?
  
  let browser: Browsing
  let cache: QueueCaching
  let target: DispatchQueue
  
  init(browser: Browsing, cache: QueueCaching, target: DispatchQueue) {
    self.browser = browser
    self.cache = cache
    self.target = target
  }
  
  private func done(with error: Error? = nil) {
    let er = isCancelled ? FeedKitError.cancelledByUser : error
    
    if let cb = entriesCompletionBlock {
      target.async {
        cb(er)
      }
    }
    
    entriesCompletionBlock = nil
    isFinished = true
    op?.cancel()
    op = nil
  }
  
  weak var op: Operation?
  
  private func fetchEntries(for locators: [EntryLocator]) {
    guard
      let entriesBlock = self.entriesBlock,
      let entriesCompletionBlock = self.entriesCompletionBlock else {
      return
    }
    
    op = browser.entries(
      locators,
      entriesBlock: entriesBlock,
      entriesCompletionBlock: entriesCompletionBlock
    )
    
    op?.completionBlock = {
      self.done()
    }
  }
  
  override func start() {
    guard !isCancelled else {
      return done()
    }
    
    isExecuting = true
    
    
    do {
      let queued = try cache.queued()
      
      var guids = [String]()
      
      let locators: [EntryLocator] = queued.flatMap {
        switch $0 {
        case .entry(let locator, _):
          guard let guid = locator.guid else {
            fatalError("missing guid")
          }
          guids.append(guid)
          return locator.including
        }
      }
      
      self.sortOrderBlock?(guids)
      
      guard !isCancelled, !locators.isEmpty else {
        return done()
      }

      fetchEntries(for: locators)
    } catch {
      done(with: error)
    }
  }
 
}

// TODO: Consider extending this into User, organized into extensions

public final class EntryQueue {
  
  let operationQueue: OperationQueue
  let queueCache: QueueCaching
  let browser: Browsing
  
  /// Creates a fresh EntryQueue object.
  ///
  /// - Parameters:
  ///   - queueCache: The cache to store the queue locallly.
  ///   - browser: The browser to retrieve entries.
  ///   - queue: The operation queue to execute operations on.
  public init(queueCache: QueueCaching, browser: Browsing, queue: OperationQueue) {
    self.queueCache = queueCache
    self.browser = browser
    self.operationQueue = queue
  }
  
  /// The actual queue data structure. Starting off with an empty queue.
  fileprivate var queue = Queue<Entry>()
  
  public var delegate: QueueDelegate?
}

// MARK: - Queueing

extension EntryQueue: Queueing {
  
  // TODO: Restore queue sort order

  /// Fetches the queued entries and provides the populated queue.
  public func entries(
    entriesBlock: @escaping (_ entriesError: Error?, _ entries: [Entry]) -> Void,
    entriesCompletionBlock: @escaping (_ error: Error?) -> Void
  ) -> Operation {
    assert(Thread.isMainThread)
    
    let cache = self.queueCache
    let target = DispatchQueue.main
    let op = FetchQueueOperation(browser: browser, cache: cache, target: target)
    
    var acc = [Entry]()
    
    var sortedGuids: [String]?
    
    op.sortOrderBlock = { guids in
      sortedGuids = guids
    }

    op.entriesBlock = { error, entries in
      guard let guids = sortedGuids else {
        fatalError("meh")
      }

      var dict = [String : Entry]()
      entries.forEach { dict[$0.guid] = $0 }
      let sorted: [Entry] = guids.flatMap { dict[$0] }
      
      acc.append(contentsOf: sorted)
      entriesBlock(error, sorted)
    }
    
    op.entriesCompletionBlock = { error in
      let unique = Set(acc)
      if acc.count != unique.count {
        // TODO: Crash here
        let (_, doublets) = acc.reduce(([String](), [String]())) { acc, entry in
          let guid = entry.guid
          let (all, doublets) = acc
          guard !all.contains(guid) else {
            return (all, doublets + [entry.title]) // title reads better
          }
          return (all + [entry.guid], doublets)
        }
        print("EntryQueue: \(#function): doublets detected: \(doublets)")
      }
      
      self.queue = Queue<Entry>(items: acc)
      
      entriesCompletionBlock(error)
    }
    
    operationQueue.addOperation(op)
    
    return op
  }
  
  private func postDidChangeNotification() {
    NotificationCenter.default.post(
      name: Notification.Name(rawValue: FeedKitQueueDidChangeNotification),
      object: self
    )
  }
  
  public func add(_ entry: Entry) throws {
    try queue.add(entry)
    
    delegate?.queue(self, added: entry)
    postDidChangeNotification()
    
    DispatchQueue.global(qos: .default).async {
      try! self.queueCache.add([EntryLocator(entry: entry)])
    }
  }
  
  public func add(entries: [Entry]) throws {
    try queue.add(items: entries)
  }
  
  public func remove(_ entry: Entry) throws {
    DispatchQueue.global(qos: .default).async {
      let entries = self.queue.enumerated()
      let guids = entries.map { $0.element.value.guid }
      try! self.queueCache.remove(guids: guids)
      try! self.queue.remove(entry)
      
      DispatchQueue.main.async {
        self.delegate?.queue(self, removedGUID: entry.guid)
        self.postDidChangeNotification()
      }
    }
  }
  
  public func contains(_ entry: Entry) -> Bool {
    return queue.contains(entry)
  }
  
  public func next() -> Entry? {
    return queue.forward()
  }
  
  public func previous() -> Entry? {
    return queue.backward()
  }
  
}

