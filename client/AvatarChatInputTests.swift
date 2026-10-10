import AppKit
import SwiftUI

@main struct AvatarChatInputTests {
 @MainActor static func main(){
  _ = NSApplication.shared
  NSApplication.shared.appearance=NSAppearance(named:.aqua)
  verifyCompositionPlaceholder()
  let input=AvatarChatInputScrollView(frame:NSRect(x:0,y:0,width:300,height:38))
  input.layoutSubtreeIfNeeded()
  precondition(input.measuredHeight==38,"empty composer must match the 38-point send button")
  input.update(text:"one\ntwo",enabled:true,label:"Question")
  precondition(input.measuredHeight==62,"two visual lines must grow upward by one line")
  input.update(text:"one\ntwo\nthree",enabled:true,label:"Question")
  precondition(input.measuredHeight==86)
  input.update(text:"one\ntwo\nthree\nfour\nfive\nsix",enabled:true,label:"Question")
  input.setFrameSize(NSSize(width:300,height:input.measuredHeight));input.layoutSubtreeIfNeeded()
  precondition(input.measuredHeight==86 && input.hasVerticalScroller,"overflow must scroll within a three-line input")
  precondition((input.documentView?.frame.height ?? 0)>input.contentView.bounds.height)
  input.contentView.scroll(to:NSPoint(x:0,y:40));input.reflectScrolledClipView(input.contentView)
  precondition(input.contentView.bounds.minY>0,"overflow document must actually scroll")
  input.update(text:"one",enabled:true,label:"Question")
  precondition(input.measuredHeight==38,"deleting text must shrink to one line")
  input.update(text:"one\n",enabled:true,label:"Question")
  precondition(input.measuredHeight==62,"a trailing newline must reveal its caret line")
  input.update(text:String(repeating:"你好",count:60),enabled:true,label:"Question")
  precondition(input.measuredHeight==86 && input.hasVerticalScroller,"soft-wrapped paste must obey the same cap")
  input.update(text:"",enabled:true,label:"Question")
  precondition(input.measuredHeight==38)
  var submitted=0
  input.editor.onSubmit={submitted+=1}
  let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
  input.editor.keyDown(with:event)
  precondition(submitted==1,"Command-Return must submit once")
  input.editor.setMarkedText("拼音",selectedRange:NSRange(location:0,length:2),replacementRange:NSRange(location:NSNotFound,length:0))
  input.editor.keyDown(with:event)
  precondition(submitted==1,"IME composition must not submit an unfinished question")
  input.editor.unmarkText()
  input.update(text:"locked",enabled:false,label:"Question")
  precondition(!input.editor.isEditable && input.editor.accessibilityLabel()=="Question")
  print("Native chat input: equal height / hard and soft wraps / three-line cap / scrolling / shrink / IME / shortcut PASS")
 }

 @MainActor static func verifyCompositionPlaceholder(){
  // The draft remains empty until an IME commits. Render the actual composer,
  // and inspect the area beyond the short marked text for a lingering hint.
  let host=NSHostingView(rootView:AvatarChatInput(text:.constant(""),enabled:true,placeholder:"This is a long composer hint",submit:{}))
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:50),styleMask:[.titled],backing:.buffered,defer:false)
  window.contentView=host;window.orderFront(nil);host.layoutSubtreeIfNeeded()
  defer{window.close()}
  RunLoop.main.run(until:Date().addingTimeInterval(0.1))
  func native(_ view:NSView)->AvatarChatTextView?{if let editor=view as? AvatarChatTextView{return editor};for child in view.subviews{if let found=native(child){return found}};return nil}
  guard let editor=native(host)else{preconditionFailure("native editor missing")}
  func hintInk()->Int{
   RunLoop.main.run(until:Date().addingTimeInterval(0.03))
   editor.displayIfNeeded();host.displayIfNeeded()
   let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!
   host.cacheDisplay(in:host.bounds,to:bitmap)
   let scale=CGFloat(bitmap.pixelsWide)/host.bounds.width
   var count=0
   for x in Int(120*scale)..<Int(245*scale){for y in Int(10*scale)..<Int(29*scale){
    if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.alphaComponent>0.5,max(color.redComponent,color.greenComponent,color.blueComponent)<0.75{count+=1}
   }}
   return count
  }
  precondition(hintInk()>30,"empty composer must visibly render its hint")
  for composition in ["nihao","ka","g"] {
   editor.setMarkedText(composition,selectedRange:NSRange(location:composition.utf16.count,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
   precondition(editor.hasMarkedText())
   precondition(hintInk()==0,"uncommitted IME input must immediately hide the hint")
   editor.setMarkedText("",selectedRange:NSRange(location:0,length:0),replacementRange:NSRange(location:NSNotFound,length:0));editor.unmarkText()
   precondition(hintInk()>30,"cancelling composition must restore the empty-input hint")
  }
  editor.insertText("hello",replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(hintInk()==0,"direct keyboard input must hide the hint too")
 }
}
