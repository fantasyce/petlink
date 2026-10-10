import Foundation

struct V2RequestBinding {
 let epoch:Int
 let accountID:String?
 func matches(epoch:Int,accountID:String?)->Bool{self.accountID != nil && self.epoch==epoch && self.accountID==accountID}
}

func canVisitFromUI(connected:Bool,online:Bool,accepting:Bool,phase:String,pending:Bool)->Bool {
 connected && online && accepting && phase == "home" && !pending
}

func normalizedCredentialPaste(_ value:String)->String { value.trimmingCharacters(in:.whitespacesAndNewlines) }
func agentStateLabel(_ state:String)->String {switch state{case "disconnected":return L10n.text("未连接");case "idle":return L10n.text("空闲");case "working":return L10n.text("工作中");case "waiting_approval":return L10n.text("等待批准");case "completed":return L10n.text("已完成");case "failed":return L10n.text("失败");default:return L10n.text("未知")}}
func agentProviderLabel(_ provider:String)->String {switch provider{case "codex":return "Codex";case "claude":return "Claude Code";case "deepseek":return "DeepSeek Harness";default:return provider}}

extension JSONDecoder {
 static var petLink:JSONDecoder {let d=JSONDecoder();d.dateDecodingStrategy = .custom{decoder in let text=try decoder.singleValueContainer().decode(String.self);let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds];if let value=fractional.date(from:text){return value};let basic=ISO8601DateFormatter();if let value=basic.date(from:text){return value};throw DecodingError.dataCorruptedError(in:try decoder.singleValueContainer(),debugDescription:"Invalid RFC3339 date")};return d}
}

struct V2Session:Codable,Equatable {
 let accountID:String;let friendID:String;let accessToken:String;let refreshToken:String
}
struct V2SocketCredentialControl:Decodable {
 let type:String;let requestID:String
 enum CodingKeys:String,CodingKey{case type;case requestID="request_id"}
}
struct V2AuthResponse:Codable {let accountID:String;let friendID:String;let accessToken:String;let refreshToken:String;let recoveryCode:String?;enum CodingKeys:String,CodingKey{case accountID="account_id",friendID="friend_id",accessToken="access_token",refreshToken="refresh_token",recoveryCode="recovery_code"}}
struct V2ProfileDTO:Codable {let style:Int?;let nicknameIsDefault:Bool?;let accountID:String;let username:String;let nickname:String;let friendID:String;let activeDevice:String;let accepting:Bool;enum CodingKeys:String,CodingKey{case style;case nicknameIsDefault="nickname_is_default",accountID="account_id",username,nickname,friendID="friend_id",activeDevice="active_device",accepting}}
struct V2AgentDTO:Codable {let provider:String;let sessionRef:String;let state:String;let sequence:Int64;let expiresAt:Date;enum CodingKeys:String,CodingKey{case provider,state,sequence;case sessionRef="session_ref",expiresAt="expires_at"}}
struct V2PetDTO:Codable,Identifiable {var id:String{ownerID};let ownerID:String;let nickname:String;let locationID:String;let targetID:String;let phase:String;let revision:Int64;let style:Int;let waveSequence:Int64;let waveExpiresAt:Date?;enum CodingKeys:String,CodingKey{case nickname,phase,revision,style;case ownerID="owner_id",locationID="location_id",targetID="target_id",waveSequence="wave_sequence",waveExpiresAt="wave_expires_at"}}
struct V2HideDTO:Codable {let petID:String;let revision:Int64;enum CodingKeys:String,CodingKey{case petID="pet_id",revision}}
struct V2ContactDTO:Codable,Identifiable {var id:String{accountID};let accountID:String;let friendID:String;let nickname:String;let style:Int;let note:String;let online:Bool;let accepting:Bool;let trusted:Bool;let shareAgent:Bool;let autoVisit:Bool;let agent:V2AgentDTO?;let allowAvatarAsk:Bool;let avatarProvider:String;let avatarPolicyRevision:Int64;let avatarKeyReady:Bool;enum CodingKeys:String,CodingKey{case nickname,style,note,online,accepting,trusted,agent;case accountID="account_id",friendID="friend_id",shareAgent="share_agent",autoVisit="auto_visit",allowAvatarAsk="allow_avatar_ask",avatarProvider="avatar_provider",avatarPolicyRevision="avatar_policy_revision",avatarKeyReady="avatar_key_ready"};init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);accountID=try c.decode(String.self,forKey:.accountID);friendID=try c.decode(String.self,forKey:.friendID);nickname=try c.decode(String.self,forKey:.nickname);let decodedStyle=try c.decodeIfPresent(Int.self,forKey:.style) ?? 0;style=(0...9).contains(decodedStyle) ? decodedStyle:0;note=try c.decode(String.self,forKey:.note);online=try c.decode(Bool.self,forKey:.online);accepting=try c.decodeIfPresent(Bool.self,forKey:.accepting) ?? true;trusted=try c.decode(Bool.self,forKey:.trusted);shareAgent=try c.decode(Bool.self,forKey:.shareAgent);autoVisit=try c.decode(Bool.self,forKey:.autoVisit);agent=try c.decodeIfPresent(V2AgentDTO.self,forKey:.agent);allowAvatarAsk=try c.decodeIfPresent(Bool.self,forKey:.allowAvatarAsk) ?? false;avatarProvider=try c.decodeIfPresent(String.self,forKey:.avatarProvider) ?? "owner_default";avatarPolicyRevision=try c.decodeIfPresent(Int64.self,forKey:.avatarPolicyRevision) ?? 0;avatarKeyReady=try c.decodeIfPresent(Bool.self,forKey:.avatarKeyReady) ?? false}}
struct V2FriendRequestDTO:Codable,Identifiable {let id:String;let fromID:String;let toID:String;let status:String;let expiresAt:Date;enum CodingKeys:String,CodingKey{case id,status;case fromID="from_id",toID="to_id",expiresAt="expires_at"}}
struct V2VisitRequestDTO:Codable,Identifiable {let id:String;let guestID:String;let hostID:String;let status:String;let expiresAt:Date;enum CodingKeys:String,CodingKey{case id,status;case guestID="guest_id",hostID="host_id",expiresAt="expires_at"}}
struct AvatarDeviceKeyDTO:Codable {let accountID:String;let deviceID:String;let keyVersion:Int64;let agreementPublicKey:String;let signingPublicKey:String;enum CodingKeys:String,CodingKey{case accountID="account_id",deviceID="device_id",keyVersion="key_version",agreementPublicKey="agreement_public_key",signingPublicKey="signing_public_key"}}
struct AvatarTaskDTO:Codable,Identifiable {let id:String;let ownerID:String;let requesterID:String;let requesterDeviceID:String;let ownerDeviceID:String;let provider:String;let state:String;let visitRevision:Int64;let policyRevision:Int64;let requestDigest:String;let resultDigest:String?;let createdAtMS:Int64;let expiresAtMS:Int64;let errorCode:String?;enum CodingKeys:String,CodingKey{case id,provider,state;case ownerID="owner_id",requesterID="requester_id",requesterDeviceID="requester_device_id",ownerDeviceID="owner_device_id",visitRevision="visit_revision",policyRevision="policy_revision",requestDigest="request_digest",resultDigest="result_digest",createdAtMS="created_at",expiresAtMS="expires_at",errorCode="error_code"}}
struct AvatarRelayDTO:Codable,Identifiable {var id:String{task.id};let task:AvatarTaskDTO;let request:AvatarEnvelopeDTO?;let result:AvatarEnvelopeDTO?;let peerKey:AvatarDeviceKeyDTO?;enum CodingKeys:String,CodingKey{case task,request,result;case peerKey="peer_key"}}
struct AvatarContactCapabilityDTO:Codable {let ownerID:String;let deviceID:String;let keyVersion:Int64;let agreementPublicKey:String;let signingPublicKey:String;let visitRevision:Int64;let policyRevision:Int64;let allowAutoAsk:Bool;let provider:String;enum CodingKeys:String,CodingKey{case provider;case ownerID="owner_id",deviceID="device_id",keyVersion="key_version",agreementPublicKey="agreement_public_key",signingPublicKey="signing_public_key",visitRevision="visit_revision",policyRevision="policy_revision",allowAutoAsk="allow_auto_ask"}}
struct V2SnapshotDTO:Codable {let requestID:String;let error:String?;let selfID:String;let own:V2PetDTO;let pets:[V2PetDTO];let hides:[V2HideDTO];let leaseMS:Int;let contacts:[V2ContactDTO];let friendRequests:[V2FriendRequestDTO];let visitRequests:[V2VisitRequestDTO];let outgoingVisits:[V2VisitRequestDTO];let visitHistory:[V2VisitRequestDTO]?;let avatarTasks:[AvatarRelayDTO]?;enum CodingKeys:String,CodingKey{case error,own,pets,hides,contacts;case requestID="request_id",selfID="self_id",leaseMS="lease_ms",friendRequests="friend_requests",visitRequests="visit_requests",outgoingVisits="outgoing_visits",visitHistory="visit_history",avatarTasks="avatar_tasks"}}
struct V2APIError:Codable,Error {let code:String;let message:String}

func visitResultLabel(_ status:String)->String {
 switch status {case "rejected":return L10n.text("对方已拒绝这次来访");case "expired":return L10n.text("来访申请已过期，请重新申请");case "cancelled":return L10n.text("来访申请已取消");case "accepted":return L10n.text("来访申请已获批准");case "completed":return L10n.text("这次来访已结束");case "pending":return L10n.text("正在等待批准");default:return L10n.text("来访状态暂不可识别，请稍后重试")}
}
func visitErrorLabel(_ code:String)->String {
 switch code {case "HOST_PAUSED":return L10n.text("对方已暂停接待，请稍后再试");case "HOST_FULL":return L10n.text("对方接待已满，请稍后再试");case "PEER_OFFLINE":return L10n.text("对方当前离线");case "REQUEST_EXISTS":return L10n.text("已有来访申请，请等待处理");case "REQUEST_EXPIRED":return L10n.text("申请已过期，请重新申请");default:return L10n.text("操作未完成（{0}）", code)}
}
