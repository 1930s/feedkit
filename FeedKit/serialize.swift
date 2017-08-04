//
//  serialize.swift - transform things into other things
//  FeedKit
//
//  Created by Michael Nisi on 10.02.15.
//  Copyright (c) 2015 Michael Nisi. All rights reserved.
//

import Foundation
import Skull
import os.log

// MARK: - Logging

@available(iOS 10.0, *)
fileprivate let log = OSLog(subsystem: "ink.codes.feedkit", category: "serialize")

/// Returns a new URL string with lowercased scheme and host, the path remains
/// as it is. Here‘s the spec: https://tools.ietf.org/html/rfc3986
///
/// - Parameter string: The URL string to use.
///
/// - Returns: RFC 3986 compliant URL or `nil`.
func lowercasedURL(string: String) -> String? {
  guard var c = URLComponents(string: string), let host = c.host else {
    return nil
  }
  c.host = host.lowercased()
  return c.string
}

fileprivate func feedURL(from json: [String : Any]) -> String? {
  // TODO: Replace feed with url in fanboy
  guard
    let rawURL = json["url"] as? String ?? json["feed"] as? String,
    let url = lowercasedURL(string: rawURL) else {
    return nil
  }
  return url
}

/// Remove whitespace from specified string and replace it with `""` or the
/// specified string. Consecutive spaces are reduced to a single space.
///
/// - Parameters:
///   - string: The string to trim..
///   - replacement: The string to replace whitespace with.
///
/// - Returns: The trimmed string.
func replaceWhitespaces(
  in string: String,
  with replacement: String = ""
  ) -> String {
  let ws = CharacterSet.whitespaces
  let ts = string.trimmingCharacters(in: ws)
  let cmps = ts.components(separatedBy: " ") as [String]
  return cmps.reduce("") { a, b in
    if a.isEmpty { return b }
    let tb = b.trimmingCharacters(in: ws)
    if tb.isEmpty { return a }
    return "\(a)\(replacement)\(tb)"
  }
}

/// A collection of serialization functions.
struct serialize {
  
  /// Create Cocoa time interval from JavaScript time.
  ///
  /// As `NSJSONSerialization` returns Foundation objects, the input for this needs
  /// to be `NSNumber`, especially to ensure we are OK on 32 bit as well.
  ///
  /// - Parameter value: A timestamp from JSON in milliseconds.
  ///
  /// - Returns: The respective time interval (in seconds):
  static func timeIntervalFromJS(_ value: NSNumber) -> TimeInterval {
    return Double(value) / 1000 as TimeInterval
  }
  
  /// Create an iTunes item from a JSON payload. All properties: guid, img100,
  /// img30, img60, and img600 must be present.
  static func iTunesItem(from dict: [String : Any]) -> ITunesItem? {
    guard
      let guid = dict["guid"] as? Int,
      let img100 = dict["img100"] as? String,
      let img30 = dict["img30"] as? String,
      let img60 = dict["img60"] as? String,
      let img600 = dict["img600"] as? String else {
        return nil
    }
    
    return ITunesItem(
      guid: guid,
      img100: img100,
      img30: img30,
      img60: img60,
      img600: img600
    )
  }
  
  /// Create and return a foundation date from a universal timestamp in
  /// milliseconds, contained in a a dictionary, matching a specified key. If the
  /// dictionary does not contain a value for the key or the value cannot be used
  /// to create a date `nil` is returned.
  ///
  /// - Parameters:
  ///   - dictionary: The dictionary to look at.
  ///   - key: The key of a potential UTC timestamp in milliseconds.
  ///
  /// - Returns: The date or `nil`.
  static func date(from dictionary: [String : Any], withKey key: String) -> Date? {
    guard let ms = dictionary[key] as? NSNumber else {
      return nil
    }
    let s = serialize.timeIntervalFromJS(ms)
    guard s > 0 else {
      return nil
    }
    return Date(timeIntervalSince1970: s)
  }
  
  /// Tries to create and return a feed from the specified dictionary.
  ///
  /// - Parameter json: The JSON dictionary to use.
  ///
  /// - Returns: The newly create feed object.
  ///
  /// - Throws: If the required properties `feed` and `title` are invalid, this
  /// function throws `FeedKitError.InvalidFeed`.
  static func feed(from json: [String : Any]) throws -> Feed {
    
    guard let url = feedURL(from: json) else {
      throw FeedKitError.invalidFeed(reason: "feed missing")
    }
    
    guard let title = json["title"] as? String else {
      throw FeedKitError.invalidFeed(reason: "title missing: \(url)")
    }
    
    let author = json["author"] as? String
    
    // Apparantly, people spam the iTunes author property. To ignore them, we
    // limit its length.
    
    if let a = author, a.characters.count > 64 {
      throw FeedKitError.invalidFeed(reason: "excessive author: \(url)")
    }
    
    // TODO: Filter shady stuff like this earlier--in the remote service
    
    let iTunes = serialize.iTunesItem(from: json)
    let image = json["image"] as? String
    let link = json["link"] as? String
    let summary = json["summary"] as? String
    let originalURL = json["originalURL"] as? String
    let updated = serialize.date(from: json, withKey: "updated")
    
    return Feed(
      author: author,
      iTunes: iTunes,
      image: image,
      link: link,
      originalURL: originalURL,
      summary: summary,
      title: title,
      ts: nil,
      uid: nil,
      updated: updated,
      url: url
    )
  }
  
  /// Create an array of feeds from a JSON payload.
  ///
  /// It should be noted, relying on our service written by ourselves, there
  /// shouldn't be any errors, handling these should be a mere safety measure for
  /// more transparent debugging. Doublets are filtered out and reported.
  ///
  /// - Parameter dicts: A JSON array of dictionaries to serialize.
  ///
  /// - Returns: A tuple of errors and feeds.
  ///
  /// - Throws: Doesn't throw but collects its errors and returns them in the
  /// result tuple alongside the feeds.
  static func feeds(from dicts: [[String : Any]]) -> ([Error], [Feed]) {
    var errors = [Error]()
    let feeds = dicts.reduce([Feed]()) { acc, dict in
      do {
        let f = try serialize.feed(from: dict)
        guard !acc.contains(f) else {
          if #available(iOS 10.0, *) {
            // Feed doublets can occure when iTunes search returns objects with
            // different GUIDs, but with equal feed URLs.
            os_log("feed doublet: %{public}@", log: log,  type: .error,
                   String(describing: f))
          }
          return acc
        }
        return acc + [f]
      } catch let er {
        errors.append(er)
        return acc
      }
    }
    return (errors, feeds)
  }
  
  /// Create an enclosure from a JSON payload.
  static func enclosure(from json: [String : Any]) throws -> Enclosure? {
    guard let url = json["url"] as? String else {
      throw FeedKitError.invalidEnclosure(reason: "missing url")
    }
    guard let t = json["type"] as? String else {
      throw FeedKitError.invalidEnclosure(reason: "missing type")
    }
    
    var length: Int?
    if let lenstr = json["length"] as? String {
      length = Int(lenstr)
    }
    let type = EnclosureType(withString: t)
    
    return Enclosure(
      url: url,
      length: length,
      type: type
    )
  }
  
  /// Tries to create and return an entry from the specified dictionary.
  ///
  /// To create a valid entry feed, title, and id are required. Also the updated
  /// timestamp is relevant, but if this isn't present, its value will be set to
  /// zero (1970-01-01 00:00:00 UTC).
  ///
  /// - Parameters:
  ///   - json: The JSON dictionary to serialize.
  ///   - podcast: Flag that having an enclosure is required.
  ///
  /// - Returns: The valid entry.
  ///
  /// - Throws: Might throw `FeedKitError.InvalidEntry` if `"feed"`, `"title"`, or
  /// `"id"` are missing from the dictionary. If enclosure is required, `podcast`
  /// is `true`, and not present, also invalid entry is thrown.
  static func entry(from json: [String : Any], podcast: Bool = true) throws -> Entry {
    guard let feed = json["url"] as? String else {
      throw FeedKitError.invalidEntry(reason: "missing feed")
    }
    guard let title = json["title"] as? String else {
      throw FeedKitError.invalidEntry(reason: "missing title: \(feed)")
    }
    guard let id = json["id"] as? String else {
      throw FeedKitError.invalidEntry(reason: "missing id: \(feed)")
    }
    
    let guid = String(djb2Hash(string: id) ^ djb2Hash(string: feed))
    
    let updated = serialize.date(from: json, withKey: "updated") ??
      Date(timeIntervalSince1970: 0)
    
    let author = json["author"] as? String
    let duration = json["duration"] as? Int
    let image = json["image"] as? String
    let link = json["link"] as? String
    let originalURL = json["originalURL"] as? String
    let subtitle = json["subtitle"] as? String
    let summary = json["summary"] as? String
    
    var enclosure: Enclosure?
    if let enc = json["enclosure"] as? [String:AnyObject] {
      enclosure = try serialize.enclosure(from: enc)
    }
    
    if podcast {
      guard enclosure != nil else {
        throw FeedKitError.invalidEntry(reason: "missing enclosure: \(feed)")
      }
    }
    
    return Entry(
      author: author,
      duration: duration,
      enclosure: enclosure,
      feed: feed,
      feedImage: nil,
      feedTitle: nil,
      guid: guid,
      iTunes: nil,
      image: image,
      link: link,
      originalURL: originalURL,
      subtitle: subtitle,
      summary: summary,
      title: title,
      ts: nil,
      updated: updated
    )
  }
  
  /// Create an array of entries from a JSON payload.
  ///
  /// - Parameter dicts: An array of—presumably—entry dictionaries.
  /// - Parameter podcast: A flag to require an enclosure for each entry.
  ///
  /// - Returns: A tuple containing errors and entries.
  ///
  /// - Throws: This function doesn't throw because it collects the entries it
  /// successfully serialized and returns them, additionally it also collects
  /// the occuring errors and returns them too. May its user act wisely!
  static func entries(from dicts: [[String: Any]], podcast: Bool = true) -> ([Error], [Entry]) {
    var errors = [Error]()
    let entries = dicts.reduce([Entry]()) { acc, dict in
      do {
        let entry = try serialize.entry(from: dict, podcast: podcast)
        return acc + [entry]
      } catch let er {
        errors.append(er)
        return acc
      }
    }
    return (errors, entries)
  }
  
}
