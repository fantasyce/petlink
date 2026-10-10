import AppKit
import SwiftUI

struct PetVisibilityButton:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var pets:PetWindows
 var willSelect:()->Void = {}
 var body:some View {Button(pets.manuallyHidden ? L10n.text("显示桌宠"):L10n.text("隐藏桌宠")){willSelect();pets.toggleVisibility()}}
}
struct PetQuickMenu:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var conversation:CodexConversationMonitor
 let outfit:()->Void
 let hide:()->Void
 var body:some View {
  PencilMenu{
   Button(L10n.text("换装"),action:outfit)
   Button {conversation.bubblesEnabled.toggle()} label:{
    HStack(spacing:6){
     Text(L10n.text("气泡"))
     ZStack(alignment:conversation.bubblesEnabled ? .trailing:.leading){
      PencilOutline(radius:9).fill(conversation.bubblesEnabled ? PetAppearance.sage:PetAppearance.canvas)
      PencilOutline(radius:9).stroke(PetAppearance.line,lineWidth:1)
      PencilOutline(radius:5).fill(conversation.bubblesEnabled ? PetAppearance.accent:PetAppearance.secondary)
       .frame(width:10,height:10).padding(3)
     }.frame(width:26,height:16).accessibilityHidden(true)
    }
   }.accessibilityLabel(L10n.text("气泡")).accessibilityValue(conversation.bubblesEnabled ? L10n.text("开启"):L10n.text("关闭")).accessibilityIdentifier("pet-bubbles-toggle")
   Button(L10n.text("隐藏"),action:hide)
  }
 }
}
