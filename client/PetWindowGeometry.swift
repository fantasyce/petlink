import AppKit

struct PetScreen {
 let id:String
 let bounds:NSRect
 static var connected:[PetScreen] {
  NSScreen.screens.map { screen in
   let number=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
   let id:String
   if let uuid=CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(){id=CFUUIDCreateString(nil,uuid) as String}else{id=String(number)}
   return PetScreen(id:id,bounds:screen.visibleFrame)
  }
 }
}
func petScreen(at point:NSPoint,screens:[PetScreen])->PetScreen? {
 if let screen=screens.first(where:{$0.bounds.contains(point)}){return screen}
 return screens.min { a,b in
  func distance(_ r:NSRect)->CGFloat {let x=max(r.minX-point.x,0,point.x-r.maxX),y=max(r.minY-point.y,0,point.y-r.maxY);return x*x+y*y}
  return distance(a.bounds)<distance(b.bounds)
 }
}

func clampedPetOrigin(_ origin:NSPoint,size:NSSize,inside bounds:NSRect)->NSPoint {
 NSPoint(x:min(max(origin.x,bounds.minX),max(bounds.minX,bounds.maxX-size.width)),y:min(max(origin.y,bounds.minY),max(bounds.minY,bounds.maxY-size.height)))
}

func visitorBubbleFrame(preferred:NSRect,inside screen:NSRect,obstacles:[NSRect])->NSRect {
 let size=preferred.size
 let xs=[preferred.minX,screen.minX,screen.maxX-size.width]+obstacles.flatMap{[$0.minX-size.width-8,$0.maxX+8]}
 let ys=[preferred.minY,screen.minY,screen.maxY-size.height]+obstacles.flatMap{[$0.minY-size.height-8,$0.maxY+8]}
 var best:NSRect?
 var distance=CGFloat.infinity
 for x in xs {for y in ys {
  let frame=NSRect(origin:clampedPetOrigin(NSPoint(x:x,y:y),size:size,inside:screen),size:size)
  guard !obstacles.contains(where:{$0.insetBy(dx:-5,dy:-5).intersects(frame)}) else{continue}
  let dx=frame.minX-preferred.minX,dy=frame.minY-preferred.minY
  let next=dx*dx+dy*dy
  if next<distance{best=frame;distance=next}
 }}
 return best ?? preferred
}

final class PetPositionStore {
 private let defaults:UserDefaults;private let profile:String
 init(defaults:UserDefaults = .standard,profile:String){self.defaults=defaults;self.profile=profile}
 private func key(_ owner:String)->String{"pet-position.\(profile).\(owner)"}
 func save(owner:String,origin:NSPoint){defaults.set([Double(origin.x),Double(origin.y)],forKey:key(owner))}
 func load(owner:String)->NSPoint?{guard let values=defaults.array(forKey:key(owner)) as? [Double],values.count==2 else{return nil};return NSPoint(x:values[0],y:values[1])}
 func save(owner:String,origin:NSPoint,screen:PetScreen){save(owner:owner,origin:origin);defaults.set(["screen":screen.id,"x":origin.x-screen.bounds.minX,"y":origin.y-screen.bounds.minY],forKey:key(owner)+".display")}
 func restore(owner:String,size:NSSize,screens:[PetScreen],fallback:NSPoint)->NSPoint {
  if let saved=defaults.dictionary(forKey:key(owner)+".display"),let id=saved["screen"] as? String,let x=saved["x"] as? Double,let y=saved["y"] as? Double,x.isFinite,y.isFinite,let screen=screens.first(where:{$0.id==id}) {
   return clampedPetOrigin(NSPoint(x:screen.bounds.minX+x,y:screen.bounds.minY+y),size:size,inside:screen.bounds)
  }
  let origin=load(owner:owner) ?? fallback
  let safe=origin.x.isFinite && origin.y.isFinite ? origin:fallback
  guard let screen=petScreen(at:safe,screens:screens)else{return fallback}
  return clampedPetOrigin(safe,size:size,inside:screen.bounds)
 }
}

final class DraggableHostingView<Content:NSView>:NSView {
 let hosted:Content;var didMove:((NSPoint)->Void)?;var didClick:(()->Void)?;var didRightClick:(()->Void)?;private var dragged=false;private var mouseOffset=NSPoint.zero
 init(_ view:Content){hosted=view;super.init(frame:view.frame);addSubview(view);view.translatesAutoresizingMaskIntoConstraints=false;NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:leadingAnchor),view.trailingAnchor.constraint(equalTo:trailingAnchor),view.topAnchor.constraint(equalTo:topAnchor),view.bottomAnchor.constraint(equalTo:bottomAnchor)])}
 required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
 func beginDrag(atWindowPoint point:NSPoint){mouseOffset=point}
 func moveDrag(toGlobal global:NSPoint,inside bounds:NSRect){guard let window else{return};let proposed=NSPoint(x:global.x-mouseOffset.x,y:global.y-mouseOffset.y);let next=clampedPetOrigin(proposed,size:window.frame.size,inside:bounds);window.setFrameOrigin(next);didMove?(next)}
 override func rightMouseDown(with event:NSEvent){didRightClick?()}
 override func mouseDown(with event:NSEvent){dragged=false;beginDrag(atWindowPoint:event.locationInWindow)}
 override func mouseUp(with event:NSEvent){if !dragged{didClick?()}}
 override func hitTest(_ point:NSPoint)->NSView?{bounds.contains(point) ? self:nil}
 override func mouseDragged(with event:NSEvent){dragged=true;let point=NSEvent.mouseLocation;guard let screen=petScreen(at:point,screens:PetScreen.connected)else{return};moveDrag(toGlobal:point,inside:screen.bounds)}
}

final class PetVisibilityStore {
 private let defaults:UserDefaults;private let key:String
 init(defaults:UserDefaults,profile:String){self.defaults=defaults;key="pet-hidden."+profile}
 var hidden:Bool {get{defaults.bool(forKey:key)}set{defaults.set(newValue,forKey:key)}}
}
