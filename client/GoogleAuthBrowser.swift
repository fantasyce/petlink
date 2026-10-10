import AppKit
import AuthenticationServices

// The system owns this authentication window. Closing the owned session never
// enumerates or changes the user's other browser tabs.
@MainActor final class GoogleAuthBrowser:NSObject,ASWebAuthenticationPresentationContextProviding {
 private var session:ASWebAuthenticationSession?
 private var generation=0
 private let onCancel:()->Void
 init(onCancel:@escaping()->Void){self.onCancel=onCancel}
 func open(_ url:URL)->Bool {
  close();let current=generation
  let auth=ASWebAuthenticationSession(url:url,callbackURLScheme:nil){[weak self] _,_ in
   Task{@MainActor in
    guard let self,self.generation==current else{return}
    self.session=nil;self.onCancel()
   }
  }
  auth.presentationContextProvider=self
  auth.prefersEphemeralWebBrowserSession=false
  session=auth
  guard auth.start() else{close();return false}
  return true
 }
 func close(){generation+=1;let old=session;session=nil;old?.cancel()}
 func presentationAnchor(for session:ASWebAuthenticationSession)->ASPresentationAnchor {
  NSApp.mainWindow ?? NSApp.windows.first(where:{$0.level == .normal}) ?? ASPresentationAnchor()
 }
}
