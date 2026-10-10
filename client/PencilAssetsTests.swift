import AppKit
import CoreText

@main struct PencilAssetsTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let fontURL=root.appendingPathComponent("Yozai-Regular.ttf")
  assert(CTFontManagerRegisterFontsForURL(fontURL as CFURL,.process,nil))
  let font=CTFontCreateWithName("Yozai-Regular" as CFString,14,nil)
  assert((CTFontCopyPostScriptName(font) as String)=="Yozai-Regular")
  let text=Array("桌宠联系人请求数字分身本地设置挥手召回接受拒绝浅深色钥匙串PetLink0123456789".utf16)
  var glyphs=[CGGlyph](repeating:0,count:text.count)
  assert(CTFontGetGlyphsForCharacters(font,text,&glyphs,text.count),"missing UI glyphs")
  for asset in ["monster","bread","cat","dog","bear"] {
  let image=NSImage(contentsOf:root.appendingPathComponent(asset+"-atlas.png"))!
  let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
  assert(abs(Double(cg.width)/Double(cg.height)-2)<0.01,"atlas must have square cells in a 4 by 2 grid")
  let rep=NSBitmapImageRep(cgImage:cg)
  assert(rep.hasAlpha,"atlas has no alpha")
  for row in 0..<2 {for col in 0..<4 {
   let x=col*cg.width/4,y=row*cg.height/2
   assert(rep.colorAt(x:x+2,y:y+2)!.alphaComponent<0.01,"opaque sprite background")
   assert(rep.colorAt(x:x+cg.width/8,y:y+cg.height/4)!.alphaComponent>0.9,"transparent body")
  }}
  }
  let license=try String(contentsOf:root.appendingPathComponent("OFL-Yozai.txt"),encoding:.utf8)
  assert(license.contains("SIL OPEN FONT LICENSE"))
  print("Bundled font registration, UI glyphs, atlas grid, transparent corners, opaque bodies and license passed")
 }
}
