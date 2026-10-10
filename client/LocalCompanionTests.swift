import Foundation
@main struct LocalCompanionTests {
 static func main(){
  let suite="petlink-local-test-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  let pet=LocalCompanion(defaults:defaults)
  precondition(pet.style==8)
  pet.setStyle(7)
  precondition(LocalCompanion(defaults:defaults).style==7)
  pet.setStyle(-1);precondition(pet.style==7)
  pet.setStyle(10);precondition(pet.style==7)
  precondition(pet.savedStyle(accountID:"account-a")==nil)
  pet.rememberStyle(6,accountID:"account-a")
  pet.rememberStyle(9,accountID:"account-b")
  let restored=LocalCompanion(defaults:defaults)
  precondition(restored.savedStyle(accountID:"account-a")==6)
  precondition(restored.savedStyle(accountID:"account-b")==9)
  precondition(restored.savedStyle(accountID:"account-c")==nil)
  restored.rememberStyle(10,accountID:"account-a")
  precondition(restored.savedStyle(accountID:"account-a")==6)
  defaults.set(-1,forKey:"account-companion-style:corrupt")
  precondition(restored.savedStyle(accountID:"corrupt")==nil)
  precondition(!LocalCompanion.requiresLogin(page:0))
  precondition(!LocalCompanion.requiresLogin(page:3))
  precondition(!LocalCompanion.requiresLogin(page:4))
  for page in [1,2,5]{precondition(LocalCompanion.requiresLogin(page:page))}
  print("Local companion persistence, style bounds and social gate PASS")
 }
}
