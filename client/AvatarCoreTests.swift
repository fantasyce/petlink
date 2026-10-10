import CryptoKit
import Foundation

@main struct AvatarCoreTests {
 static func check(_ value:@autoclosure()->Bool,_ message:String){if !value(){fatalError(message)}}

 static func main()throws{
  let owner=AvatarDeviceIdentity.generate()
  let requester=AvatarDeviceIdentity.generate()
  let created=Date(timeIntervalSince1970:1_789_523_000.123)
  let metadata=AvatarEnvelopeMetadata(taskID:"dlg_test",senderAccountID:"requester",senderDeviceID:"device-b",recipientAccountID:"owner",recipientDeviceID:"device-a",visitRevision:42,policyRevision:7,sequence:18,createdAt:created,expiresAt:created.addingTimeInterval(60))
  let payload=AvatarQuestionPayload(question:"今天应该先做什么？")
  let envelope=try AvatarCrypto.seal(payload,metadata:metadata,sender:requester,recipientAgreementPublicKey:owner.agreementPublicKey)
  check(envelope.verify(signingPublicKey:requester.signingPublicKey),"valid signature rejected")
  let opened:AvatarQuestionPayload=try AvatarCrypto.open(envelope,recipient:owner,as:AvatarQuestionPayload.self)
  check(opened==payload,"roundtrip mismatch")
  let failure=AvatarAnswerPayload(answer:"",provider:"claude",completedAt:created,errorCode:"AGENT_EXECUTION_FAILED")
  let failedEnvelope=try AvatarCrypto.seal(failure,metadata:metadata,sender:requester,recipientAgreementPublicKey:owner.agreementPublicKey)
  let failedResult=try AvatarCrypto.open(failedEnvelope,recipient:owner,as:AvatarAnswerPayload.self)
  check(failedResult.errorCode=="AGENT_EXECUTION_FAILED","encrypted failure lost stable code")

  var tampered=envelope
  tampered.ciphertext=Data("tampered".utf8).base64URLEncodedString()
  check(!tampered.verify(signingPublicKey:requester.signingPublicKey),"tampered ciphertext verified")
  do{let _:AvatarQuestionPayload=try AvatarCrypto.open(tampered,recipient:owner,as:AvatarQuestionPayload.self);fatalError("tampered ciphertext decrypted")}catch{}

  check(envelope.canonicalSignable().contains("created_at_ms=1789523000123"),"canonical timestamp is not millisecond stable")
  check(!envelope.canonicalSignable().contains(payload.question),"plaintext leaked into signed envelope")
  check(envelope.encodedSize<=48*1024,"envelope exceeds transport limit")
  // Fractional milliseconds are common in Date(). Signatures must survive
  // exactly the JSON boundary used by the HTTP client and WebSocket relay.
  for offset in [0.0001,0.0006,0.0009,0.0019,0.9999] {
   let date=Date(timeIntervalSince1970:1_789_523_000+offset)
   let m=AvatarEnvelopeMetadata(taskID:"dlg_wire",senderAccountID:"requester",senderDeviceID:"device-b",recipientAccountID:"owner",recipientDeviceID:"device-a",visitRevision:42,policyRevision:7,sequence:19,createdAt:date,expiresAt:date.addingTimeInterval(120))
   let sealed=try AvatarCrypto.seal(payload,metadata:m,sender:requester,recipientAgreementPublicKey:owner.agreementPublicKey)
   let wire=try JSONEncoder.avatar.encode(sealed)
   let received=try JSONDecoder.avatar.decode(AvatarEnvelopeDTO.self,from:wire)
   check(received.verify(signingPublicKey:requester.signingPublicKey),"signature invalid after JSON roundtrip at offset \(offset); before=\(sealed.canonicalSignable().components(separatedBy:"\n").filter{$0.contains("_ms=")}); after=\(received.canonicalSignable().components(separatedBy:"\n").filter{$0.contains("_ms=")})")
  }
  print("Avatar core: signed E2EE roundtrip / tamper / canonical timestamps PASS")
 }
}
