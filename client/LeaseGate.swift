import Foundation

struct LeaseGate {
 private var pending: [String: TimeInterval] = [:]
 private var latest: TimeInterval = -1
 private var deadline: TimeInterval = 0
 mutating func sent(_ id: String, at time: TimeInterval) {
  pending = pending.filter {time - $0.value < 10}
  pending[id] = time
 }
 mutating func accept(_ id: String, now: TimeInterval, leaseMS: Int) -> Bool {
  guard let sent = pending.removeValue(forKey: id), sent >= latest else {return false}
  let end = sent + Double(min(max(leaseMS, 0), 3000))/1000
  guard now < end else {return false}
  latest = sent; deadline = end; return true
 }
 func valid(at now: TimeInterval) -> Bool {now < deadline}
 mutating func reset() {pending.removeAll(); deadline = 0; latest = -1}
}
