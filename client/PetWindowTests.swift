import AppKit

func expect(_ value:Bool,_ message:String){if !value{fatalError(message)}}

@main struct PetWindowTests {
 static func main(){
  let bounds=NSRect(x:0,y:0,width:1000,height:700),size=NSSize(width:180,height:160)
  expect(clampedPetOrigin(NSPoint(x:-20,y:900),size:size,inside:bounds)==NSPoint(x:0,y:540),"clamp offscreen")
  expect(clampedPetOrigin(NSPoint(x:400,y:200),size:size,inside:bounds)==NSPoint(x:400,y:200),"preserve valid position")
  let defaults=UserDefaults(suiteName:"com.fantasyce.petlink.tests.positions")!;defaults.removePersistentDomain(forName:"com.fantasyce.petlink.tests.positions")
  let store=PetPositionStore(defaults:defaults,profile:"qa");store.save(owner:"alice",origin:NSPoint(x:410,y:220));expect(store.load(owner:"alice")==NSPoint(x:410,y:220),"position roundtrip")
  defer{defaults.removePersistentDomain(forName:"com.fantasyce.petlink.tests.positions")}
  let left=PetScreen(id:"left",bounds:bounds),right=PetScreen(id:"right",bounds:NSRect(x:1000,y:0,width:1200,height:900))
  expect(petScreen(at:NSPoint(x:1300,y:300),screens:[left,right])?.id=="right","drag chooses destination screen")
  store.save(owner:"multi",origin:NSPoint(x:1200,y:200),screen:right)
  expect(store.restore(owner:"multi",size:size,screens:[left,right],fallback:.zero)==NSPoint(x:1200,y:200),"relaunch ignores main screen")
  let moved=PetScreen(id:"right",bounds:NSRect(x:-1200,y:700,width:1200,height:900))
  expect(store.restore(owner:"multi",size:size,screens:[left,moved],fallback:.zero)==NSPoint(x:-1000,y:900),"screen rearrangement retains local offset")
  let fallback=store.restore(owner:"multi",size:size,screens:[left],fallback:.zero)
  expect(bounds.contains(NSRect(origin:fallback,size:size)),"unplug falls back to visible screen")
  expect(store.restore(owner:"multi",size:size,screens:[left,right],fallback:.zero)==NSPoint(x:1200,y:200),"fallback did not overwrite unplugged display position")
  let smaller=PetScreen(id:"right",bounds:NSRect(x:1000,y:0,width:300,height:200))
  expect(store.restore(owner:"multi",size:size,screens:[left,smaller],fallback:.zero)==NSPoint(x:1120,y:40),"scaled visible area clamps without losing saved offset")
  expect(store.restore(owner:"multi",size:size,screens:[left,right],fallback:.zero)==NSPoint(x:1200,y:200),"scale recovery restores saved offset")
	let panel=NSPanel(contentRect:NSRect(x:100,y:100,width:180,height:160),styleMask:.borderless,backing:.buffered,defer:false);let drag=DraggableHostingView(NSView(frame:NSRect(x:0,y:0,width:180,height:160)));panel.contentView=drag;var saved:NSPoint?;drag.didMove={saved=$0};drag.beginDrag(atWindowPoint:NSPoint(x:40,y:50));drag.moveDrag(toGlobal:NSPoint(x:500,y:400),inside:bounds);expect(panel.frame.origin==NSPoint(x:460,y:350),"explicit drag changes panel origin");expect(saved==panel.frame.origin,"drag persists position")
  let visibility=PetVisibilityStore(defaults:defaults,profile:"qa")
  expect(!visibility.hidden,"default visible")
  visibility.hidden=true
  expect(PetVisibilityStore(defaults:defaults,profile:"qa").hidden,"manual hide survives restart")
  expect(!PetVisibilityStore(defaults:defaults,profile:"other").hidden,"profile isolated")
  visibility.hidden=false
  var rightClicked=false;drag.didRightClick={rightClicked=true}
  let event=NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  drag.rightMouseDown(with:event);expect(rightClicked,"right click routed to custom menu")
  print("Pet windows: clamp and persisted positions PASS")
 }
}
