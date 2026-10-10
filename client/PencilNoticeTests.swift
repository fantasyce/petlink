import Foundation

@main struct PencilNoticeTests {
 static func main() {
  assert(PencilNoticeMotion.duration == 1.2)
  for height in [32.0,72.0,148.0] {
   for step in 0...100 {
    let p=Double(step)/100
    let state=PencilNoticeMotion.layout(height:height,spacing:20,progress:p)
    let visibleBottom=height+state.messageOffset
    assert(abs(state.reservedHeight-(height+20)*p)<0.00001,"following content must move with the actual revealed height")
    assert(abs(state.reservedHeight-state.messageOffset-(height+20))<0.00001,"message and following content must travel exactly the same distance")
    assert(visibleBottom<=state.reservedHeight,"notice must never overlap the pet or following content")
   }
   let closed=PencilNoticeMotion.layout(height:height,spacing:20,progress:0)
   assert(closed.reservedHeight==0 && closed.messageOffset <= -height,"closing must release all reserved space and fully conceal the message")
  }
  assert(PencilNoticeMotion.layout(height:50,spacing:20,progress: -1).reservedHeight==0)
  assert(PencilNoticeMotion.layout(height:50,spacing:20,progress:2).reservedHeight==70)
  print("PASS synchronized notice layout: multi-line sizes, equal travel, no overlap, full return and bounded progress")
 }
}
