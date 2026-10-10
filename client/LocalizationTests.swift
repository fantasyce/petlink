import Foundation
import Combine

@main struct LocalizationTests {
 static func main() {
  let suite="petlink-localization-tests-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  var preferred=["en-GB","zh-Hans-CN"]
  let resources=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let language=AppLocalization(defaults:defaults,resources:resources,preferredLanguages:{preferred})
  precondition(language.text("好友互动")=="Friend interactions","System language must choose English")
  language.select(.chinese)
  precondition(language.text("好友互动")=="好友互动")
  let restored=AppLocalization(defaults:defaults,resources:resources,preferredLanguages:{preferred})
  precondition(restored.selection == .chinese,"Explicit language must survive relaunch")
  preferred=["zh-Hant-TW","en-US"]
  language.select(.system)
  precondition(language.languageID=="zh-Hans")
  preferred=["fr-FR","en-US"]
  language.refreshSystemLanguage()
  precondition(language.languageID=="en","Unsupported languages fall back to English")
  precondition(language.text("好友 ID：{0}","Test{1}%🐾")=="Friend ID: Test{1}%🐾","Arguments must remain literal")
  precondition(language.notice("正在等待 TestC 批准")=="Waiting for TestC to approve","Existing notices must follow a language change")
  language.select(.chinese)
  precondition(language.notice("Waiting for TestC to approve")=="正在等待 TestC 批准")
  language.select(.english)
  precondition(language.notice("未安装")=="Not installed","Stored detection labels must follow language changes")
  precondition(language.notice("未命名对话")=="Untitled conversation","Stored generated titles must follow language changes")
  precondition(language.text("未知键")=="未知键","Unknown messages retain their text")
  print("Localization selection, persistence, fallback, placeholders and live notices passed")
 }
}
