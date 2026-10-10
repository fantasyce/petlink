import Foundation
import CoreGraphics

@main struct PetInteractionTests {
 static func main() {
  precondition(PetLinkNavigation.pages(authenticated:false)==[0,1,3,4],"unsigned social area must expose only the contact login entry")
  precondition(PetLinkNavigation.pages(authenticated:true)==[0,1,2,3,4],"friend chat belongs to contacts, without a separate avatar tab")
  precondition(PetLinkNavigation.pages(authenticated:true,delivered:1)==[0,1,2,3,4],"only the request tab is delivered")
  precondition(PetLinkNavigation.selection(5,authenticated:false)==1,"logout from hidden history returns to contacts")
  precondition(PetLinkNavigation.selection(3,authenticated:false)==3,"local Agent remains usable without login")
  precondition(SocialUnlockMotion.delivered(elapsed:0,reduced:false)==0)
  precondition(SocialUnlockMotion.duration>=6,"delivery must allow time to see the pet after returning from Google")
  precondition(SocialUnlockMotion.delivered(elapsed:3,reduced:false)==0)
  precondition(SocialUnlockMotion.delivered(elapsed:5.8,reduced:false)==1,"the requests tab arrives after the slow delivery")
  precondition(SocialUnlockMotion.delivered(elapsed:0,reduced:true)==1,"reduced motion immediately exposes all tabs")
  // Delivery follows the live request slot, rather than former sidebar coordinates.
  let source=CGRect(x:80,y:100,width:280,height:280)
  let requests=CGRect(x:116,y:508,width:42,height:44)
  let first=SocialUnlockMotion.pose(elapsed:0,source:source,requests:requests)
  let delivery=SocialUnlockMotion.pose(elapsed:5.8,source:source,requests:requests)
  precondition(first.petX==220 && first.petY==240 && first.petSize==280,"courier starts on the actual showroom pet")
  precondition(delivery.cardX==137 && delivery.cardY==530 && delivery.page==2,"requests lands in its bottom slot")
  precondition(delivery.petY>first.petY && delivery.petSize==90,"pet travels down and shrinks to carry the first tab")
  precondition(SocialUnlockMotion.delivered(elapsed:5.79,reduced:false)==0,"neither tab appears before the shared delivery")
  for tick in 0..<580 {
   let pose=SocialUnlockMotion.pose(elapsed:Double(tick)/100,source:source,requests:requests)
   precondition(pose.cardY-22 >= pose.petY+pose.petSize/2+8,"cards must remain below the pet")
  }
  let returned=SocialUnlockMotion.pose(elapsed:SocialUnlockMotion.duration,source:source,requests:requests)
  precondition(returned.petX==220 && returned.petY==240 && returned.petSize==280,"courier returns without a jump to the showroom")
  let wideSource=CGRect(x:260,y:160,width:280,height:280)
  let lowRequests=CGRect(x:116,y:708,width:42,height:44)
  let resizedFirst=SocialUnlockMotion.pose(elapsed:5.8,source:wideSource,requests:lowRequests)
  let resizedReturn=SocialUnlockMotion.pose(elapsed:SocialUnlockMotion.duration,source:wideSource,requests:lowRequests)
  precondition(resizedFirst.cardY==730 && resizedFirst.cardX==137,"delivery follows the request slot after resize")
  precondition(resizedReturn.petX==400 && resizedReturn.petY==300,"resize updates the return position too")
  let id="01a0f04a-b01a-7281-a7d7-66158fab3bd0"
  let path="/tmp/rollout-2026-09-30T11-10-23-"+id+".jsonl"
  precondition(CodexThreadLink.url(forPath:path)?.absoluteString=="codex://threads/"+id,"bubble must open its own exact thread")
  for invalid in ["/tmp/evil.jsonl","/tmp/"+id+".txt","/tmp/rollout-evil?command=delete.jsonl"] {precondition(CodexThreadLink.url(forPath:invalid)==nil,"unrecognized filenames must not become deep links")}
  print("Social login navigation / staged pet delivery / reduced motion / exact Codex link PASS")
 }
}
