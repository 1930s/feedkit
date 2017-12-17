//
//  PrepareUpdateOperation.swift
//  FeedKit
//
//  Created by Michael Nisi on 15.12.17.
//  Copyright © 2017 Michael Nisi. All rights reserved.
//

import Foundation
import os.log

extension PrepareUpdateOperation {

  /// Merges `locators` with `subscriptions`, where the timestamps found in
  /// `locators` override those in `subscriptions`.
  static func merge(
    _ locators: [EntryLocator],
    with subscriptions: [Subscription]) -> [EntryLocator] {
    var datesByURLs = [FeedURL: Date]()
    for loc in locators {
      let url = loc.url
      if let prev = datesByURLs[url], prev > loc.since {
        continue
      }
      datesByURLs[url] = loc.since
    }
    return subscriptions.map {
      let url = $0.url
      let ts = $0.ts

      if let prev = datesByURLs[url], prev > ts {
        return EntryLocator(url: url, since: prev)
      }

      return EntryLocator(url: url, since: ts)
    }
  }
}

final class PrepareUpdateOperation: Operation, ProvidingLocators {
  private(set) var error: Error?
  private(set) var locators = [EntryLocator]()

  fileprivate let cache: UserCaching

  init(cache: UserCaching) {
    self.cache = cache
  }

  override func main() {
    do {
      let subscriptions = try cache.subscribed()
      let latest = try cache.newest()
      self.locators = PrepareUpdateOperation.merge(latest, with: subscriptions)
      os_log("** prepared: %{public}@", log: User.log, type: .debug, locators)
    } catch {
      self.error = error
    }
  }
}