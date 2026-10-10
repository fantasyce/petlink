import CryptoKit
import Foundation
// Serializes first load per profile without running Security.framework on the UI actor.
// Successful loads remain cached; failed loads may be retried. No ACL or storage fallback changes.
actor AvatarIdentityLoader {
 private var loads:[String:Task<AvatarDeviceIdentity,Error>]=[:]
 func load(profile:String,store:any AvatarIdentityStore=AvatarKeychainIdentityStore(),createIfMissing:Bool=true)async throws->AvatarDeviceIdentity {
  if let task=loads[profile]{return try await task.value}
  let task=Task.detached{try AvatarIdentityVault.loadOrCreate(profile:profile,store:store,createIfMissing:createIfMissing)}
  loads[profile]=task
  do{return try await task.value}catch{loads[profile]=nil;throw error}
 }
}
import Security

enum AvatarIdentityError:Error {case missing}

protocol AvatarIdentityStore {
 func read(service:String,account:String)throws->Data?
 func write(_ data:Data,service:String,account:String)throws
 func delete(service:String,account:String)
}

struct AvatarKeychainIdentityStore:AvatarIdentityStore {
 func read(service:String,account:String)throws->Data? {let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne];var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item);if status==errSecItemNotFound{return nil};guard status==errSecSuccess,let data=item as? Data else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))};return data}
 func write(_ data:Data,service:String,account:String)throws {let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account];let values:[String:Any]=[kSecValueData as String:data];let status=SecItemUpdate(query as CFDictionary,values as CFDictionary);if status==errSecSuccess{return};guard status==errSecItemNotFound else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))};var add=query;add.merge(values){_,new in new};add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;let created=SecItemAdd(add as CFDictionary,nil);guard created==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(created))}}
 func delete(service:String,account:String){let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account];SecItemDelete(query as CFDictionary)}
}

enum AvatarIdentityVault {
 private struct StoredIdentity:Codable {let agreementPrivateKey:String;let signingPrivateKey:String;enum CodingKeys:String,CodingKey{case agreementPrivateKey="agreement_private_key",signingPrivateKey="signing_private_key"}}
 private static func service(_ profile:String)throws->String {guard !profile.isEmpty,profile.count<=80,profile.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="-")})else{throw CocoaError(.fileWriteInvalidFileName)};return "com.fantasyce.petlink.avatar."+profile}
 static func encode(_ identity:AvatarDeviceIdentity)throws->Data {try JSONEncoder().encode(StoredIdentity(agreementPrivateKey:identity.agreementPrivateKey.rawRepresentation.base64URLEncodedString(),signingPrivateKey:identity.signingPrivateKey.rawRepresentation.base64URLEncodedString()))}
 static func decode(_ data:Data)throws->AvatarDeviceIdentity {let stored=try JSONDecoder().decode(StoredIdentity.self,from:data);guard let agreement=Data(base64URL:stored.agreementPrivateKey),let signing=Data(base64URL:stored.signingPrivateKey)else{throw AvatarCryptoError.invalidKey};return AvatarDeviceIdentity(agreementPrivateKey:try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:agreement),signingPrivateKey:try Curve25519.Signing.PrivateKey(rawRepresentation:signing))}
 static func read(profile:String,store:any AvatarIdentityStore=AvatarKeychainIdentityStore())->AvatarDeviceIdentity? {guard let service=try? service(profile)else{return nil};do{guard let data=try store.read(service:service,account:"device-identity")else{return nil};return try decode(data)}catch{return nil}}
 static func loadOrCreate(profile:String,store:any AvatarIdentityStore=AvatarKeychainIdentityStore(),createIfMissing:Bool=true)throws->AvatarDeviceIdentity {let service=try service(profile);if let data=try store.read(service:service,account:"device-identity"){return try decode(data)};guard createIfMissing else{throw AvatarIdentityError.missing};let identity=AvatarDeviceIdentity.generate();try store.write(encode(identity),service:service,account:"device-identity");guard let persisted=try store.read(service:service,account:"device-identity")else{throw AvatarCryptoError.invalidKey};return try decode(persisted)}
 static func delete(profile:String,store:any AvatarIdentityStore=AvatarKeychainIdentityStore()){guard let service=try? service(profile)else{return};store.delete(service:service,account:"device-identity")}
}
