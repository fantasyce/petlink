import Foundation
import CoreGraphics
@main struct ShiftTests {
 static func main(){
  precondition(SocialUnlockMotion.agentShift(elapsed:0,reduced:false)==0)
  precondition(SocialUnlockMotion.agentShift(elapsed:1,reduced:false)>0 && SocialUnlockMotion.agentShift(elapsed:1,reduced:false)<52)
  precondition(SocialUnlockMotion.agentShift(elapsed:2,reduced:false)==52)
  precondition(SocialUnlockMotion.agentShift(elapsed:0,reduced:true)==52)
  let source=CGRect(x:80,y:90,width:280,height:280),requests=CGRect(x:116,y:608,width:42,height:44)
  var previous=0.0
  for tick in 0...800 {
   let t=Double(tick)/100,shift=SocialUnlockMotion.agentShift(elapsed:t,reduced:false)
   precondition(shift>=previous && shift<=52);previous=shift
   let a=SocialUnlockMotion.pose(elapsed:t,source:source,requests:requests)
   if t<=1.9 {precondition(a.petY==source.midY && a.petSize==280 && a.cardOpacity==0,"pet delivery must wait until Agent has moved")}
   if a.cardOpacity>0 {precondition(a.cardY-22>=a.petY+a.petSize/2+8,"the request card remains below the pet")}
  }
  precondition(SocialUnlockMotion.delivered(elapsed:5.79,reduced:false)==0)
  precondition(SocialUnlockMotion.delivered(elapsed:5.8,reduced:false)==1)
  print("Agent continuous 52px shift / complete before pet movement / simultaneous delivery / clearance / reduced motion PASS")
 }
}
