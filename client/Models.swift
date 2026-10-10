import Foundation
import Security
import LocalAuthentication

struct Pet: Codable, Identifiable {
 var id: String {owner}
 let owner: String; let name: String; let location: String; let target: String
 let phase: String; let revision: Int64; let style: Int; let wave: Int64
}
struct Friend: Codable, Identifiable {
 let id: String; let name: String; let online: Bool; let allowed: Bool; let canVisit: Bool
 enum CodingKeys: String, CodingKey {case id,name,online,allowed;case canVisit="can_visit"}
}
struct Hide: Codable {let pet:String;let revision:Int64}
struct Snapshot: Codable {
 let id:String;let error:String;let selfID:String;let name:String;let own:Pet
 let pets:[Pet];let friends:[Friend];let hides:[Hide];let leaseMS:Int
 enum CodingKeys:String,CodingKey {case id,error,name,own,pets,friends,hides;case selfID="self";case leaseMS="lease_ms"}
}
protocol SessionStore {
 func read(_ profile:String)->String?
 func write(_ value:String,profile:String)throws->Bool
 func delete(_ profile:String)
}
struct PrivateFileSessionStore:SessionStore {
 func read(_ profile:String)->String?{Vault.read(profile)}
 func write(_ value:String,profile:String)throws->Bool{try Vault.write(value,profile:profile)}
 func delete(_ profile:String){Vault.delete(profile)}
}
/// Enqueue synchronously on the UI actor; execute serially away from it.
/// Returning a Task does not delay enqueueing or allow later saves to overtake logout.
final class SessionPersistence {
 private let queue=DispatchQueue(label:"com.fantasyce.petlink.session-storage")
 private let store:any SessionStore
 init(store:any SessionStore=PrivateFileSessionStore()){self.store=store}
 private func enqueue<T>(_ work:@escaping ()throws->T)->Task<T,Error>{
  let result=StorageResult<T>()
  queue.async{result.resolve(Result{try work()})}
  return Task{try await result.value()}
 }
 func read(profile:String)->Task<String?,Error>{enqueue{self.store.read(profile)}}
 func write(_ value:String,profile:String)->Task<Bool,Error>{enqueue{try self.store.write(value,profile:profile)}}
 func delete(profile:String)->Task<Void,Error>{enqueue{self.store.delete(profile)}}
}
private final class StorageResult<T> {
 private let lock=NSLock();private var result:Result<T,Error>?;private var continuation:CheckedContinuation<T,Error>?
 func resolve(_ value:Result<T,Error>){lock.lock();result=value;let waiter=continuation;continuation=nil;lock.unlock();waiter?.resume(with:value)}
 func value()async throws->T {try await withCheckedThrowingContinuation{waiter in lock.lock();if let value=result{lock.unlock();waiter.resume(with:value)}else{continuation=waiter;lock.unlock()}}}
}

enum Vault {
 static func fileURL(_ profile:String)throws->URL {
  guard !profile.isEmpty,profile.count<=64,profile.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="-")}) else{throw CocoaError(.fileWriteInvalidFileName)}
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PetLink/Identity/"+profile+"/session")
 }
 static func usesPrivateFile(_ profile:String)->Bool {guard let url=try? fileURL(profile) else{return false};return FileManager.default.fileExists(atPath:url.path)}
 static func service(_ profile:String)->String {"com.fantasyce.petlink."+profile}
 static func read(_ profile:String)->String? {
  if usesPrivateFile(profile){return readPrivateFile(profile)}
  // One-time legacy migration never opens a Keychain permission dialog.
  let context=LAContext();context.interactionNotAllowed=true
  let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service(profile),kSecAttrAccount as String:"session",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationContext as String:context]
  var item:CFTypeRef?
  guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data,let value=String(data:data,encoding:.utf8) else{return nil}
  do{try writePrivateFile(value,profile:profile);_ = removeLegacySession(profile);return value}catch{return nil}
 }
 static func removeLegacySession(_ profile:String)->OSStatus {
  let context=LAContext();context.interactionNotAllowed=true
  let q:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service(profile),kSecAttrAccount as String:"session",kSecUseAuthenticationContext as String:context]
  return SecItemDelete(q as CFDictionary)
 }

 static func readPrivateFile(_ profile:String)->String? {
  guard let url=try? fileURL(profile),let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),
        (attrs[.posixPermissions] as? NSNumber)?.intValue==0o600,
        (attrs[.ownerAccountID] as? NSNumber)?.uint32Value==getuid(),
        attrs[.type] as? FileAttributeType == .typeRegular else{return nil}
  guard let value=try? String(contentsOf:url,encoding:.utf8),!value.isEmpty else{return nil}
  return value
 }
 static func writePrivateFile(_ token:String,profile:String)throws {
  let url=try fileURL(profile),dir=url.deletingLastPathComponent(),fm=FileManager.default
  try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  for folder in [dir,dir.deletingLastPathComponent()] {
   let attrs=try fm.attributesOfItem(atPath:folder.path)
   guard attrs[.type] as? FileAttributeType == .typeDirectory,(attrs[.ownerAccountID] as? NSNumber)?.uint32Value==getuid() else{throw CocoaError(.fileWriteNoPermission)}
   try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
  }
  let temp=dir.appendingPathComponent(UUID().uuidString)
  let fd=open(temp.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
  guard fd>=0 else{throw CocoaError(.fileWriteUnknown)}
  var done=false;defer{close(fd);if !done{unlink(temp.path)}}
  let data=Array(token.utf8)
  let count=data.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,data.count)}
  guard count==data.count,fsync(fd)==0,rename(temp.path,url.path)==0 else{throw CocoaError(.fileWriteUnknown)}
  done=true
 }
 @discardableResult static func write(_ token:String,profile:String)throws->Bool {
  try writePrivateFile(token,profile:profile)
  return true
 }
 static func delete(_ profile:String){
  // The empty file remains authoritative after logout, including older builds.
  try? writePrivateFile("",profile:profile)
 }
}
