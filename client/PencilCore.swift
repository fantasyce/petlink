import Foundation
import Combine
import CoreGraphics

enum PencilNoticeMotion {
 static let duration:Double=1.2
 static func layout(height:Double,spacing:Double,progress:Double)->(reservedHeight:Double,messageOffset:Double) {
  let distance=max(0,height)+max(0,spacing),fraction=min(1,max(0,progress))
  return (distance*fraction,-distance*(1-fraction))
 }
}

// Existing monster IDs 0/1 are retained; new accounts start with bread (8).
enum PetSpecies:Int,CaseIterable,Identifiable {
 case monster=0,dog=1,cat=2,bear=3,bread=4
 var id:Int {rawValue}
 static let displayOrder:[PetSpecies] = [.bread,.cat,.dog,.bear,.monster]
 var name:String {switch self{case .monster:return L10n.text("小怪兽");case .dog:return L10n.text("小狗");case .cat:return L10n.text("小猫");case .bear:return L10n.text("小熊");case .bread:return L10n.text("奶香吐司")}}
 var asset:String {switch self{case .monster:return "monster-atlas";case .dog:return "dog-atlas";case .cat:return "cat-atlas";case .bear:return "bear-atlas";case .bread:return "bread-atlas"}}
 static func decode(style:Int)->PetSpecies {style>=0 ? (PetSpecies(rawValue:style/2) ?? .monster):.monster}
 func style(outfit:Int)->Int {rawValue*2+(outfit==1 ? 1:0)}
}
struct PetAppearanceDraft {
 let originalStyle:Int
 private(set) var previewStyle:Int
 init(style:Int){originalStyle=style;previewStyle=style}
 var hasChanges:Bool {previewStyle != originalStyle}
 mutating func selectSpecies(_ species:PetSpecies){previewStyle=species.style(outfit:previewStyle%2)}
 mutating func selectOutfit(_ outfit:Int){previewStyle=PetSpecies.decode(style:previewStyle).style(outfit:outfit)}
 mutating func cancel(){previewStyle=originalStyle}
}
func showroomFrame(time:TimeInterval,wave:PencilWave?,reducedMotion:Bool)->Int {
 guard !reducedMotion else{return 0}
 let frame=wave?.frame(now:time,reducedMotion:false) ?? 0
 return frame>0 ? frame:(Int(time*5)%29==0 ? 3:0)
}
func pencilCenteredTitleRect(width:CGFloat)->CGRect {
 CGRect(x:108,y:8,width:max(0,width-216),height:32)
}
func reconciledContactDetailID(_ selected:String?,allContactIDs:[String])->String? {
 guard let selected,allContactIDs.contains(selected) else{return nil}
 return selected
}

enum PencilTheme:String,CaseIterable { case light,dark,system }
final class PencilPreferences:ObservableObject {
 private let defaults:UserDefaults
 private let key:String
 @Published var appearance:PencilTheme { didSet { defaults.set(appearance.rawValue,forKey:key) } }
 init(profile:String,defaults:UserDefaults = .standard) {
  self.defaults=defaults;key="pencil-appearance."+profile
  appearance=PencilTheme(rawValue:defaults.string(forKey:key) ?? "") ?? .light
 }
}

struct PencilWave {
 private var start:TimeInterval = 0
 private var end:TimeInterval = 0
 mutating func enqueue(count:Int,now:TimeInterval) {
  if now>=end {start=now;end=now}
  end=min(now+1.6,end+Double(max(1,min(count,4)))*0.4)
 }
 func sway(now:TimeInterval,reducedMotion:Bool)->Double {
  guard !reducedMotion,now>=start,now<end else{return 0}
  return 6*sin((now-start)*2*Double.pi/0.4)*min(1,(end-now)/0.08)
 }
 func frame(now:TimeInterval,reducedMotion:Bool)->Int {
  guard !reducedMotion,now>=start,now<end else{return 0}
  return Int((now-start)/0.14)%2+1
 }
}
func pencilPanelHeight(available:Double,content:Double)->Double {
 min(max(1,available-24),max(180,content))
}
