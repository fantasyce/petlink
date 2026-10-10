import AppKit

@main struct VisitorBubblePlacementTests {
 static func main(){
  let screen=NSRect(x:0,y:0,width:1440,height:700)
  let own=NSRect(x:950,y:198,width:340,height:420)
  let preferred=NSRect(x:980,y:198,width:280,height:120)
  let first=visitorBubbleFrame(preferred:preferred,inside:screen,obstacles:[own])
  let second=visitorBubbleFrame(preferred:preferred,inside:screen,obstacles:[own,first])
  precondition(screen.contains(first) && screen.contains(second))
  precondition(!first.intersects(own) && !second.intersects(own) && !second.intersects(first),"all obstacles must be checked, including after downward placement")
  precondition(visitorBubbleFrame(preferred:preferred,inside:screen,obstacles:[])==preferred)
  print("Visitor bubble placement: local/multiple guest coexistence and bounds PASS")
 }
}
