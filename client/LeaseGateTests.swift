import Foundation

@main struct Tests {
 static func main() {
  var gate = LeaseGate()
  gate.sent("fresh", at: 10)
  assert(gate.accept("fresh", now: 10.5, leaseMS: 3000))
  assert(gate.valid(at: 12.9))
  assert(!gate.valid(at: 13.0))
  gate.sent("late", at: 20)
  assert(!gate.accept("late", now: 24, leaseMS: 3000))
  assert(!gate.accept("unknown", now: 24, leaseMS: 3000))
  gate.sent("before-sleep", at: 30)
  gate.reset()
  assert(!gate.accept("before-sleep", now: 31, leaseMS: 3000))
  gate.sent("a", at: 40); gate.sent("b", at: 41)
  assert(gate.accept("b", now: 41.1, leaseMS: 3000))
  assert(!gate.accept("a", now: 41.2, leaseMS: 3000))
  print("LeaseGate: fresh / expiry / delayed / unknown / sleep / out-of-order PASS")
 }
}
