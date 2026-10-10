import SwiftUI

@main struct SocialUnlockLifecycleTests {
 @MainActor static func main(){
  // Completion is delivered synchronously; SwiftUI can observe authentication
  // afterward. That second notification must not cancel the running courier.
  let completedFirst=SocialUnlockPresentation()
  completedFirst.played=true;completedFirst.started=10
  let delivery=Task<Void,Never>{}
  completedFirst.task=delivery
  completedFirst.authenticatedChanged(true)
  precondition(completedFirst.started==10 && completedFirst.played,"authentication refresh must preserve the delivery already started by completion")
  completedFirst.authenticatedChanged(false)
  precondition(completedFirst.started==nil && !completedFirst.played,"logout must cancel delivery and allow the next login")
  precondition(delivery.isCancelled && completedFirst.task==nil,"logout must cancel the scheduled delivery completion")

  let authenticatedFirst=SocialUnlockPresentation()
  authenticatedFirst.authenticatedChanged(true)
  precondition(authenticatedFirst.started==nil && !authenticatedFirst.played,"restored authentication alone must not replay delivery")
  authenticatedFirst.played=true;authenticatedFirst.started=20
  authenticatedFirst.authenticatedChanged(true)
  precondition(authenticatedFirst.started==20)
  authenticatedFirst.cancel()
  precondition(authenticatedFirst.started==nil && authenticatedFirst.played,"navigation cancels motion without replaying this login")
  print("Social unlock notification ordering / restored login / logout / navigation PASS")
 }
}
