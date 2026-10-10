import Foundation

/// A short, process-only projection of an already decrypted friend chat.
struct VisitorChatBubble:Equatable {
 let taskID:String,ownerID:String,name:String,message:String
 let isAnswer:Bool
}
