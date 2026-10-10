import Foundation
import CoreGraphics
import Combine

final class SocialUnlockPresentation:ObservableObject {
 @Published var started:TimeInterval?
 var played=false
 var task:Task<Void,Never>?
 func cancel(){task?.cancel();task=nil;started=nil}
 func authenticatedChanged(_ authenticated:Bool){if !authenticated {cancel();played=false}}
 deinit{task?.cancel()}
}
final class LocalCompanion {
 private let defaults:UserDefaults
 private(set) var style:Int=8
 init(defaults:UserDefaults){self.defaults=defaults;if let value=defaults.object(forKey:"local-companion-style") as? Int,(0...9).contains(value){style=value}}
 func setStyle(_ value:Int){guard (0...9).contains(value) else{return};style=value;defaults.set(value,forKey:"local-companion-style")}
 func savedStyle(accountID:String)->Int? {
  guard let value=defaults.object(forKey:"account-companion-style:"+accountID) as? Int,(0...9).contains(value) else{return nil}
  return value
 }
 func rememberStyle(_ value:Int,accountID:String){
  guard (0...9).contains(value) else{return}
  if savedStyle(accountID:accountID) != value{defaults.set(value,forKey:"account-companion-style:"+accountID)}
  if style != value{setStyle(value)}
 }
 static func requiresLogin(page:Int)->Bool{[1,2,5].contains(page)}
}

enum PetLinkNavigation {
 static func pages(authenticated:Bool,delivered:Int=2)->[Int] {
  [0,1]+(authenticated && delivered>0 ? [2]:[])+[3,4]
 }
 static func selection(_ page:Int,authenticated:Bool)->Int {
  page==5 || (!authenticated && page==2) ? 1:page
 }
}

struct SocialUnlockPose {
 let petX:Double,petY:Double,petSize:Double,cardX:Double,cardY:Double,cardOpacity:Double
 let page:Int
}
enum SocialUnlockMotion {
 static let duration=8.0
 static let delivery=5.8
 static func agentShift(elapsed:Double,reduced:Bool)->Double {
  guard !reduced else{return 52}
  let t=max(0,min(1,(elapsed-0.3)/1.6))
  return 52*t*t*(3-2*t)
 }
 static func delivered(elapsed:Double,reduced:Bool)->Int {reduced || elapsed>=delivery ? 1:0}
 static func pose(elapsed:Double,source:CGRect,requests:CGRect)->SocialUnlockPose {
  func ease(_ start:Double,_ end:Double)->Double {let t=max(0,min(1,(elapsed-start)/(end-start)));return t*t*(3-2*t)}
  let target=requests
  let approach=ease(2.1,4.8)
  let retreat=ease(6.4,duration)
  let travel=approach*(1-retreat)
  let x=source.midX+(requests.midX-source.midX)*travel
  let y=source.midY+(requests.midY-82-source.midY)*travel
  let size=source.width+(90-source.width)*travel
  let insert=ease(4.8,delivery)
  let carryX=x,carryY=y+size/2+34
  return .init(petX:x,petY:y,petSize:size,cardX:carryX+(target.midX-carryX)*insert,cardY:carryY+(target.midY-carryY)*insert,cardOpacity:elapsed>=2.1 && elapsed<delivery ? 1:0,page:2)
 }
}
