import AppKit
import SwiftUI

private final class AvatarChatHintLabel:NSTextField {override func hitTest(_ point:NSPoint)->NSView?{nil}}
final class AvatarChatTextView:NSTextView {
 var onSubmit:(()->Void)?
 private lazy var hint:AvatarChatHintLabel={
  let label=AvatarChatHintLabel(labelWithString:"")
  label.textColor=NSColor(PetAppearance.secondary);label.lineBreakMode = .byTruncatingTail
  label.setAccessibilityElement(false);addSubview(label)
  return label
 }()
 var placeholder=""{didSet{refreshPlaceholder()}}
 func refreshPlaceholder(){
  hint.stringValue=placeholder;hint.font=font
  hint.isHidden = !string.isEmpty || hasMarkedText()
  hint.frame=NSRect(x:textContainerInset.width,y:textContainerInset.height+2,width:max(0,bounds.width-textContainerInset.width*2),height:24)
 }
 override func layout(){super.layout();refreshPlaceholder()}
 override func didChangeText(){super.didChangeText();refreshPlaceholder()}
 override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange){
  super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
  refreshPlaceholder()
 }
 override func unmarkText(){super.unmarkText();refreshPlaceholder()}
 override func keyDown(with event:NSEvent){
  if [36,76].contains(event.keyCode),event.modifierFlags.contains(.command),!hasMarkedText(),isEditable{onSubmit?();return}
  super.keyDown(with:event)
 }
}

final class AvatarChatInputScrollView:NSScrollView,NSTextViewDelegate {
 let editor=AvatarChatTextView(frame:.zero)
 private(set) var measuredHeight:CGFloat=38
 var heightChanged:((CGFloat)->Void)?
 var textChanged:((String)->Void)?
 private var measuring=false
 override init(frame:NSRect){
  super.init(frame:frame)
  drawsBackground=false;borderType = .noBorder;scrollerStyle = .overlay
  autohidesScrollers=true;hasHorizontalScroller=false
  editor.isRichText=false;editor.importsGraphics=false;editor.allowsUndo=true
  editor.drawsBackground=false;editor.textColor=NSColor(PetAppearance.ink)
  editor.font=NSFont(name:PencilFont.name,size:15) ?? NSFont.systemFont(ofSize:15)
  let paragraph=NSMutableParagraphStyle();paragraph.minimumLineHeight=24;paragraph.maximumLineHeight=24
  editor.defaultParagraphStyle=paragraph
  editor.typingAttributes=[.font:editor.font!,.paragraphStyle:paragraph,.foregroundColor:editor.textColor!]
  editor.textContainerInset=NSSize(width:12,height:7)
  editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
  editor.minSize = .zero;editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
  editor.autoresizingMask = [.width]
  editor.textContainer?.lineFragmentPadding=0
  editor.textContainer?.widthTracksTextView=true;editor.textContainer?.heightTracksTextView=false
  editor.delegate=self;documentView=editor
  measure()
 }
 required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
 override func layout(){super.layout();measure()}
 func update(text:String,enabled:Bool,label:String,placeholder:String=""){
  editor.placeholder=placeholder
  editor.isEditable=enabled;editor.isSelectable=true;editor.setAccessibilityLabel(label)
  editor.textColor=NSColor(PetAppearance.ink)
  if editor.string != text && !editor.hasMarkedText(){editor.string=text;applyTextStyle()}
  editor.refreshPlaceholder()
  measure()
 }
 func textDidChange(_ notification:Notification){applyTextStyle();measure();textChanged?(editor.string)}
 private func applyTextStyle(){
  guard let paragraph=editor.defaultParagraphStyle else{return}
  editor.textStorage?.addAttributes([.font:editor.font!,.paragraphStyle:paragraph,.foregroundColor:editor.textColor!],range:NSRange(location:0,length:editor.string.utf16.count))
 }
 private func measure(){
  guard !measuring,let container=editor.textContainer,let layout=editor.layoutManager else{return}
  measuring=true;defer{measuring=false}
  let width=max(40,contentSize.width)
  editor.setFrameSize(NSSize(width:width,height:max(38,editor.frame.height)))
  container.containerSize=NSSize(width:max(16,width-24),height:CGFloat.greatestFiniteMagnitude)
  layout.ensureLayout(for:container)
  var textHeight=layout.usedRect(for:container).height
  if layout.extraLineFragmentTextContainer === container {textHeight=max(textHeight,layout.extraLineFragmentRect.maxY)}
  let lines=max(1,Int(ceil(textHeight/24)))
  let height=38+CGFloat(min(3,lines)-1)*24
  hasVerticalScroller=lines>3
  editor.setFrameSize(NSSize(width:width,height:max(height,textHeight+14)))
  if height != measuredHeight{measuredHeight=height;heightChanged?(height)}
  if lines<=3 {contentView.scroll(to:.zero)}
  reflectScrolledClipView(contentView)
 }
}

private struct NativeAvatarChatInput:NSViewRepresentable {
 @ObservedObject private var language=AppLocalization.shared
 @Binding var text:String
 @Binding var height:CGFloat
 let enabled:Bool,label:String,placeholder:String
 let submit:()->Void
 func makeNSView(context:Context)->AvatarChatInputScrollView {
  let view=AvatarChatInputScrollView(frame:NSRect(x:0,y:0,width:300,height:38))
  return view
 }
 func updateNSView(_ view:AvatarChatInputScrollView,context:Context){
  view.textChanged={text=$0}
  view.heightChanged={value in DispatchQueue.main.async{if height != value{height=value}}}
  view.editor.onSubmit=submit
  view.update(text:text,enabled:enabled,label:label,placeholder:placeholder)
 }
}

private final class AvatarChatInputPresentation:ObservableObject {@Published var height:CGFloat=38}
struct AvatarChatInput:View {
 @ObservedObject private var language=AppLocalization.shared
 @Binding var text:String
 let enabled:Bool
 var placeholder=L10n.text("说点什么…")
 let submit:()->Void
 @StateObject private var presentation=AvatarChatInputPresentation()
 var body:some View {
  NativeAvatarChatInput(text:$text,height:$presentation.height,enabled:enabled,label:L10n.text("聊天消息"),placeholder:placeholder,submit:submit)
   .frame(height:presentation.height)
   .background(enabled ? PetAppearance.surface:PetAppearance.canvas,in:PencilOutline())
   .overlay(PencilOutline().stroke(PetAppearance.line.opacity(enabled ? 0.75:0.35),lineWidth:1).allowsHitTesting(false))
   .accessibilityIdentifier("avatar-question")
 }
}
