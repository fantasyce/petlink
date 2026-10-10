import SwiftUI

enum SocialUnlockAnchor:Hashable {case showroom,requests}
struct SocialUnlockAnchors:PreferenceKey {
 static var defaultValue:[SocialUnlockAnchor:Anchor<CGRect>]=[:]
 static func reduce(value:inout [SocialUnlockAnchor:Anchor<CGRect>],nextValue:()->[SocialUnlockAnchor:Anchor<CGRect>]) {value.merge(nextValue(),uniquingKeysWith:{$1})}
}

struct SocialUnlockCourier:View {
 @ObservedObject private var language=AppLocalization.shared
 let style:Int
 let elapsed:Double
 let source:CGRect,requests:CGRect
 var body:some View {
  let pose=SocialUnlockMotion.pose(elapsed:elapsed,source:source,requests:requests)
  ZStack(alignment:.topLeading) {
   PetArt(style:style,frame:2,size:pose.petSize).position(x:pose.petX,y:pose.petY)
   Image(systemName:"tray")
    .font(.system(size:21,weight:.light)).frame(width:42,height:44)
    .background(PetAppearance.sage,in:PencilOutline(radius:12))
    .overlay(PencilOutline(radius:12).stroke(PetAppearance.line.opacity(0.6),lineWidth:0.8))
    .position(x:pose.cardX,y:pose.cardY).opacity(pose.cardOpacity)
  }.allowsHitTesting(false).accessibilityHidden(true)
 }
}
