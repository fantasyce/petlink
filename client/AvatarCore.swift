import CryptoKit
import Foundation

// Sign and transmit the same integer milliseconds. Formatting a raw Date
// independently can round up after a signature truncated its fractional part.
enum AvatarWireTime {
 static func milliseconds(_ date:Date)->Int64 {Int64((date.timeIntervalSince1970*1000).rounded())}
 static func string(_ date:Date)->String {
  let ms=milliseconds(date)
  let seconds=Int64(floor(Double(ms)/1000))
  let formatter=ISO8601DateFormatter()
  formatter.formatOptions=[.withInternetDateTime]
  let base=formatter.string(from:Date(timeIntervalSince1970:Double(seconds)))
  return String(base.dropLast())+String(format:".%03dZ",Int(ms-seconds*1000))
 }
}

extension Data {
 func base64URLEncodedString()->String {base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
 init?(base64URL:String){var text=base64URL.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");let padding=(4-text.count%4)%4;text += String(repeating:"=",count:padding);self.init(base64Encoded:text)}
}

struct AvatarDeviceIdentity {
 let agreementPrivateKey:Curve25519.KeyAgreement.PrivateKey
 let signingPrivateKey:Curve25519.Signing.PrivateKey
 var agreementPublicKey:String{agreementPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()}
 var signingPublicKey:String{signingPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()}
 static func generate()->AvatarDeviceIdentity{AvatarDeviceIdentity(agreementPrivateKey:.init(),signingPrivateKey:.init())}
}

struct AvatarEnvelopeMetadata {
 let taskID:String
 let senderAccountID:String
 let senderDeviceID:String
 let recipientAccountID:String
 let recipientDeviceID:String
 let visitRevision:Int64
 let policyRevision:Int64
 let sequence:Int64
 let createdAt:Date
 let expiresAt:Date
}

struct AvatarEnvelopeDTO:Codable,Equatable {
 let version:Int
 let taskID:String
 let senderAccountID:String
 let senderDeviceID:String
 let recipientAccountID:String
 let recipientDeviceID:String
 let visitRevision:Int64
 let policyRevision:Int64
 let sequence:Int64
 let createdAt:Date
 let expiresAt:Date
 let ephemeralPublicKey:String
 let nonce:String
 var ciphertext:String
 var signature:String

 enum CodingKeys:String,CodingKey {case version,sequence,nonce,ciphertext,signature;case taskID="task_id",senderAccountID="sender_account_id",senderDeviceID="sender_device_id",recipientAccountID="recipient_account_id",recipientDeviceID="recipient_device_id",visitRevision="visit_revision",policyRevision="policy_revision",createdAt="created_at",expiresAt="expires_at",ephemeralPublicKey="ephemeral_public_key"}

 func canonicalSignable()->String {[
  "version=\(version)","task_id=\(taskID)","sender_account_id=\(senderAccountID)","sender_device_id=\(senderDeviceID)","recipient_account_id=\(recipientAccountID)","recipient_device_id=\(recipientDeviceID)","visit_revision=\(visitRevision)","policy_revision=\(policyRevision)","sequence=\(sequence)","created_at_ms=\(AvatarWireTime.milliseconds(createdAt))","expires_at_ms=\(AvatarWireTime.milliseconds(expiresAt))","ephemeral_public_key=\(ephemeralPublicKey)","nonce=\(nonce)","ciphertext=\(ciphertext)"].joined(separator:"\n")}
 func verify(signingPublicKey:String)->Bool{guard let keyData=Data(base64URL:signingPublicKey),let sig=Data(base64URL:signature),let key=try? Curve25519.Signing.PublicKey(rawRepresentation:keyData)else{return false};return key.isValidSignature(sig,for:Data(canonicalSignable().utf8))}
 var encodedSize:Int{(try? JSONEncoder.avatar.encode(self).count) ?? Int.max}
}

struct AvatarQuestionPayload:Codable,Equatable {let question:String}
struct AvatarAnswerPayload:Codable,Equatable {
 let answer:String;let provider:String;let completedAt:Date;let errorCode:String?
 init(answer:String,provider:String,completedAt:Date,errorCode:String?=nil){self.answer=answer;self.provider=provider;self.completedAt=completedAt;self.errorCode=errorCode}
 enum CodingKeys:String,CodingKey{case answer,provider;case completedAt="completed_at",errorCode="error_code"}
}

enum AvatarCryptoError:Error {case invalidKey,invalidEnvelope,payloadTooLarge}

enum AvatarCrypto {
 private static func key(_ privateKey:Curve25519.KeyAgreement.PrivateKey,_ publicKey:String,_ taskID:String)throws->SymmetricKey{
  guard let raw=Data(base64URL:publicKey),let peer=try? Curve25519.KeyAgreement.PublicKey(rawRepresentation:raw)else{throw AvatarCryptoError.invalidKey}
  let secret=try privateKey.sharedSecretFromKeyAgreement(with:peer)
  return secret.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data("PetLink Avatar v1".utf8),sharedInfo:Data(taskID.utf8),outputByteCount:32)
 }
 static func seal<T:Encodable>(_ payload:T,metadata:AvatarEnvelopeMetadata,sender:AvatarDeviceIdentity,recipientAgreementPublicKey:String)throws->AvatarEnvelopeDTO{
  let plaintext=try JSONEncoder.avatar.encode(payload);guard plaintext.count<=32*1024 else{throw AvatarCryptoError.payloadTooLarge}
  let ephemeral=Curve25519.KeyAgreement.PrivateKey();let symmetric=try key(ephemeral,recipientAgreementPublicKey,metadata.taskID)
  let nonce=ChaChaPoly.Nonce();let sealed=try ChaChaPoly.seal(plaintext,using:symmetric,nonce:nonce)
  let cipher=sealed.ciphertext+sealed.tag
  var envelope=AvatarEnvelopeDTO(version:1,taskID:metadata.taskID,senderAccountID:metadata.senderAccountID,senderDeviceID:metadata.senderDeviceID,recipientAccountID:metadata.recipientAccountID,recipientDeviceID:metadata.recipientDeviceID,visitRevision:metadata.visitRevision,policyRevision:metadata.policyRevision,sequence:metadata.sequence,createdAt:metadata.createdAt,expiresAt:metadata.expiresAt,ephemeralPublicKey:ephemeral.publicKey.rawRepresentation.base64URLEncodedString(),nonce:Data(nonce).base64URLEncodedString(),ciphertext:cipher.base64URLEncodedString(),signature:"")
  envelope.signature=try sender.signingPrivateKey.signature(for:Data(envelope.canonicalSignable().utf8)).base64URLEncodedString()
  return envelope
 }
 static func open<T:Decodable>(_ envelope:AvatarEnvelopeDTO,recipient:AvatarDeviceIdentity,as type:T.Type)throws->T{
  guard let nonceData=Data(base64URL:envelope.nonce),let combined=Data(base64URL:envelope.ciphertext),combined.count>=16 else{throw AvatarCryptoError.invalidEnvelope}
  let symmetric=try key(recipient.agreementPrivateKey,envelope.ephemeralPublicKey,envelope.taskID)
  let nonce=try ChaChaPoly.Nonce(data:nonceData);let ciphertext=combined.dropLast(16);let tag=combined.suffix(16)
  let box=try ChaChaPoly.SealedBox(nonce:nonce,ciphertext:ciphertext,tag:tag)
  let plaintext=try ChaChaPoly.open(box,using:symmetric)
  return try JSONDecoder.avatar.decode(T.self,from:plaintext)
 }
}

extension JSONEncoder {
 static var avatar:JSONEncoder {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];e.dateEncodingStrategy = .custom{date,encoder in var c=encoder.singleValueContainer();try c.encode(AvatarWireTime.string(date))};return e}
}
extension JSONDecoder {
 static var avatar:JSONDecoder {let d=JSONDecoder();d.dateDecodingStrategy = .custom{decoder in let text=try decoder.singleValueContainer().decode(String.self);let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard let date=f.date(from:text)else{throw AvatarCryptoError.invalidEnvelope};return date};return d}
}
