import Foundation

@main struct PencilCoreTests {
 static func main() {
  let suite="petlink-pencil-tests-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let a=PencilPreferences(profile:"a",defaults:defaults)
  assert(a.appearance == .light)
  a.appearance = .dark
  assert(PencilPreferences(profile:"a",defaults:defaults).appearance == .dark)
  assert(PencilPreferences(profile:"b",defaults:defaults).appearance == .light)
  a.appearance = .system
  assert(PencilPreferences(profile:"a",defaults:defaults).appearance == .system)
  var wave=PencilWave()
  wave.enqueue(count:2,now:10)
  assert(wave.frame(now:10.01,reducedMotion:false)==1)
  assert(wave.frame(now:10.18,reducedMotion:false)==2)
  assert(wave.frame(now:10.4,reducedMotion:false)==1)
  assert(wave.frame(now:11,reducedMotion:false)==0)
  assert(wave.frame(now:10.2,reducedMotion:true)==0)
  wave.enqueue(count:1000,now:20)
  assert(wave.frame(now:22,reducedMotion:false)==0)
  assert(wave.sway(now:20.1,reducedMotion:false)>0)
  assert(wave.sway(now:20.3,reducedMotion:false)<0)
  assert(wave.sway(now:20.1,reducedMotion:true)==0)
  assert(wave.sway(now:22,reducedMotion:false)==0)
  assert(pencilPanelHeight(available:300,content:800)==276)
  assert(pencilPanelHeight(available:900,content:400)==400)
  var draft=PetAppearanceDraft(style:1)
  draft.selectSpecies(.dog)
  assert(draft.previewStyle==3 && draft.originalStyle==1,"preview must retain the outfit and not commit")
  draft.selectOutfit(0)
  assert(draft.previewStyle==2)
  draft.cancel()
  assert(draft.previewStyle==1 && !draft.hasChanges,"cancel must restore original appearance")
  draft.selectSpecies(.cat)
  assert(draft.previewStyle==5)
  assert(PetSpecies.decode(style:7) == .bear)
  assert(PetSpecies.decode(style:99) == .monster)
  assert(showroomFrame(time:0.1,wave:nil,reducedMotion:true)==0)
  assert(pencilCenteredTitleRect(width:440).midX==220)
  assert(reconciledContactDetailID("friend",allContactIDs:["friend"])=="friend","list filtering must not remove a valid detail")
  assert(reconciledContactDetailID("friend",allContactIDs:[])==nil,"deletion/blocking must return to list")
  assert(reconciledContactDetailID(nil,allContactIDs:["friend"])==nil)
  print("Pencil preferences, bounded wave timeline and panel sizing passed")
 }
}
