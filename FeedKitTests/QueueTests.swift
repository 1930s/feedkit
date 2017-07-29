//
//  QueueTests.swift
//  FeedKit
//
//  Created by Michael on 6/9/17.
//  Copyright © 2017 Michael Nisi. All rights reserved.
//

import XCTest

@testable import FeedKit

final class QueueTests: XCTestCase {
  
  fileprivate var queue: Queue<Int>!
  
  override func setUp() {
    super.setUp()
    queue = Queue()
  }
  
  override func tearDown() {
    queue = nil
    super.tearDown()
  }
  
  fileprivate var items = [1, 2, 3, 4, 5, 6, 7, 8]
  
  private func populate() {
    try! self.queue.add(items: items)
  }
  
  func testSkipTo() {
    XCTAssertThrowsError(try queue.skip(to: 6)) { er in
      switch er {
      case QueueError.notInQueue:
        break
      default:
        XCTFail()
      }
    }
    
    populate()
    
    try! queue.skip(to: 6)
    
    XCTAssertEqual(queue.nextUp, [7, 8])
    XCTAssertEqual(queue.current, 6)
    
    XCTAssertEqual(queue.forward(), 7)
    
    XCTAssertEqual(queue.backward(), 6)
    
    XCTAssertEqual(queue.nextUp, [7, 8])
  }
  
  func testNextUp() {
    XCTAssertEqual(queue.nextUp, [])
    populate()
    XCTAssertEqual(queue.current, 1)
    
    XCTAssertEqual(queue.forward(), 2)
    
    XCTAssertEqual(queue.nextUp, [3,4,5,6,7,8])
  }
  
  func testForward() {
    XCTAssertNil(queue.forward())
    
    populate()
    XCTAssertEqual(queue.current, 1)
    
    let now = 4
    
    for i in 2...now {
      XCTAssertEqual(queue.forward(), i)
    }
    
    XCTAssertEqual(queue.current, now)
    XCTAssertEqual(queue.forward(), 5)
  }
  
  func testBackward() {
    XCTAssertNil(queue.backward())
    
    populate()
    XCTAssertEqual(queue.current, 1)
    
    XCTAssertNil(queue.backward())
    
    let now = 4
    
    for i in 2...now {
      XCTAssertEqual(queue.forward(), i)
    }
    
    XCTAssertEqual(queue.current, now)
    XCTAssertEqual(queue.backward(), 3)
  }
  
  func testRemove() {
    XCTAssertThrowsError(try queue.remove(11), "should throw") { er in
      switch er {
      case QueueError.notInQueue:
        break
      default:
        XCTFail()
      }
    }
    
    populate()
    
    for i in 1...8 {
      try! queue.remove(i)
    }
    
    XCTAssertNil(queue.forward())
    XCTAssertNil(queue.backward())
    
    for i in 1...8 {
      XCTAssertFalse(queue.contains(i))
    }
  }
  
  func testAdd() {
    try! queue.add(items: [1, 2, 3])
    XCTAssertEqual(queue.current, 1)
    
    XCTAssertThrowsError(try queue.add(1), "should throw") { er in
      switch er {
      case QueueError.alreadyInQueue:
        break
      default:
        XCTFail()
      }
    }
    
    try! queue.add(5)
    XCTAssertEqual(queue.current, 1)
    
    try! queue.skip(to: 5)
    XCTAssertEqual(queue.current, 5)
  }
}
