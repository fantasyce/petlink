import Foundation

// A long-lived test peer retains ephemeral private keys only in memory while
// Go relays both directions through real HTTP handlers and snapshots.
@main struct AvatarWireInteropTests {
 struct Case:Codable {let request:AvatarEnvelopeDTO;let result:AvatarEnvelopeDTO}
 struct Fixture:Codable {let ownerAgreement:String;let ownerSigning:String;let requesterAgreement:String;let requesterSigning:String;let cases:[Case]}
 struct Returned:Decodable {let envelopes:[AvatarEnvelopeDTO]}
 static func main()throws {
  let args=CommandLine.arguments
  guard args.count==3 else{throw AvatarCryptoError.invalidEnvelope}
  let owner=AvatarDeviceIdentity.generate(),requester=AvatarDeviceIdentity.generate()
  let base=floor(Date().timeIntervalSince1970)
  var cases:[Case]=[]
  for (i,offset) in [0.0001,0.0006,0.0009,0.0019,0.9999].enumerated() {
   let date=Date(timeIntervalSince1970:base+offset),task="dlg_wire_\(i)"
   let requestMeta=AvatarEnvelopeMetadata(taskID:task,senderAccountID:args[2],senderDeviceID:"requester-device",recipientAccountID:args[1],recipientDeviceID:"owner-device",visitRevision:2,policyRevision:0,sequence:Int64(i+1),createdAt:date,expiresAt:date.addingTimeInterval(120))
   let resultMeta=AvatarEnvelopeMetadata(taskID:task,senderAccountID:args[1],senderDeviceID:"owner-device",recipientAccountID:args[2],recipientDeviceID:"requester-device",visitRevision:2,policyRevision:0,sequence:Int64(i+1),createdAt:date,expiresAt:date.addingTimeInterval(120))
   cases.append(Case(request:try AvatarCrypto.seal(AvatarQuestionPayload(question:"wire question"),metadata:requestMeta,sender:requester,recipientAgreementPublicKey:owner.agreementPublicKey),result:try AvatarCrypto.seal(AvatarAnswerPayload(answer:"wire answer",provider:"claude",completedAt:date,errorCode:i==4 ? "AGENT_EXECUTION_FAILED":nil),metadata:resultMeta,sender:owner,recipientAgreementPublicKey:requester.agreementPublicKey)))
  }
  let fixture=Fixture(ownerAgreement:owner.agreementPublicKey,ownerSigning:owner.signingPublicKey,requesterAgreement:requester.agreementPublicKey,requesterSigning:requester.signingPublicKey,cases:cases)
  FileHandle.standardOutput.write(try JSONEncoder.avatar.encode(fixture)+Data([10]))
  guard let line=readLine(),let bytes=line.data(using:.utf8)else{throw AvatarCryptoError.invalidEnvelope}
  let returned=try JSONDecoder.petLink.decode(Returned.self,from:bytes)
  guard returned.envelopes.count==cases.count*2 else{throw AvatarCryptoError.invalidEnvelope}
  for e in returned.envelopes {
   if e.senderAccountID==args[1] {
    let payload=try AvatarCrypto.open(e,recipient:requester,as:AvatarAnswerPayload.self)
    guard e.verify(signingPublicKey:owner.signingPublicKey),payload.answer=="wire answer",payload.errorCode==(e.taskID=="dlg_wire_4" ? "AGENT_EXECUTION_FAILED":nil) else{throw AvatarCryptoError.invalidEnvelope}
   } else {
    guard e.verify(signingPublicKey:requester.signingPublicKey),try AvatarCrypto.open(e,recipient:owner,as:AvatarQuestionPayload.self).question=="wire question" else{throw AvatarCryptoError.invalidEnvelope}
   }
  }
 }
}
