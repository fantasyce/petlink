import Foundation
import Combine

enum AppLanguage:String,CaseIterable {
 case system,chinese="zh-Hans",english="en"
}

final class AppLocalization:ObservableObject {
 static let shared=AppLocalization()
 @Published private(set) var selection:AppLanguage
 @Published private(set) var languageID:String
 var locale:Locale{Locale(identifier:languageID)}
 private let defaults:UserDefaults
 private let preferredLanguages:()->[String]
 private let catalogs:[String:[String:String]]
 private let lock=NSLock()
 private var activeLanguage:String
 private var localeObserver:NSObjectProtocol?
 private static let preferenceKey="petlink-language"
 private static let placeholders=try! NSRegularExpression(pattern:#"\{(\d+)\}"#)
 private struct NoticeTemplate {
  let key:String,expression:NSRegularExpression,positions:[Int]
 }
 private let noticeTemplates:[NoticeTemplate]
 private let noticeKeys:[String:String]

 init(defaults:UserDefaults = .standard,resources:URL? = Bundle.main.resourceURL,preferredLanguages:@escaping ()->[String] = {Locale.preferredLanguages}) {
  self.defaults=defaults;self.preferredLanguages=preferredLanguages
  let initial=AppLanguage(rawValue:defaults.string(forKey:Self.preferenceKey) ?? "") ?? .system
  selection=initial
  let resolved=Self.resolve(initial,preferred:preferredLanguages())
  languageID=resolved;activeLanguage=resolved
  var loaded:[String:[String:String]]=[:]
  for language in ["en","zh-Hans"] {
   if let url=resources?.appendingPathComponent(language+".lproj/Localizable.strings"),
      let data=try? Data(contentsOf:url),
      let dictionary=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:String] {
    loaded[language]=dictionary
   }
  }
  catalogs=loaded
  var exact:[String:String]=[:],templates:[NoticeTemplate]=[]
  for key in (loaded["zh-Hans"] ?? [:]).keys.sorted() {
   for value in Set([key,loaded["en"]?[key] ?? key]) {
    let matches=Self.placeholders.matches(in:value,range:NSRange(value.startIndex...,in:value))
    if matches.isEmpty {exact[value]=key;continue}
    var pattern="^",positions:[Int]=[],start=value.startIndex
    for match in matches {
     guard let range=Range(match.range,in:value),let digit=Range(match.range(at:1),in:value),let position=Int(value[digit]) else{continue}
     pattern+=NSRegularExpression.escapedPattern(for:String(value[start..<range.lowerBound]))+"([\\s\\S]*?)"
     positions.append(position);start=range.upperBound
    }
    pattern+=NSRegularExpression.escapedPattern(for:String(value[start...]))+"$"
    if let expression=try? NSRegularExpression(pattern:pattern){templates.append(NoticeTemplate(key:key,expression:expression,positions:positions))}
   }
  }
  noticeKeys=exact
  noticeTemplates=templates.sorted{$0.key.count>$1.key.count}
  localeObserver=NotificationCenter.default.addObserver(forName:NSLocale.currentLocaleDidChangeNotification,object:nil,queue:.main){[weak self] _ in self?.refreshSystemLanguage()}
 }
 private static func resolve(_ selection:AppLanguage,preferred:[String])->String {
  guard selection == .system else{return selection.rawValue}
  for language in preferred {
   let code=language.lowercased().replacingOccurrences(of:"_",with:"-")
   if code=="zh" || code.hasPrefix("zh-"){return "zh-Hans"}
   if code=="en" || code.hasPrefix("en-"){return "en"}
  }
  return "en"
 }
 func select(_ language:AppLanguage) {
  defaults.set(language.rawValue,forKey:Self.preferenceKey)
  selection=language;refreshSystemLanguage()
 }
 func refreshSystemLanguage() {
  let resolved=Self.resolve(selection,preferred:preferredLanguages())
  lock.lock();activeLanguage=resolved;lock.unlock()
  if languageID != resolved{languageID=resolved}
 }
 func text(_ key:String,_ arguments:Any...)->String{render(key,arguments:arguments)}
 fileprivate func render(_ key:String,arguments:[Any])->String {
  lock.lock();let language=activeLanguage;lock.unlock()
  let template=catalogs[language]?[key] ?? key
  var result="",start=template.startIndex
  for match in Self.placeholders.matches(in:template,range:NSRange(template.startIndex...,in:template)) {
   guard let range=Range(match.range,in:template),let digit=Range(match.range(at:1),in:template),let index=Int(template[digit]) else{continue}
   result+=template[start..<range.lowerBound]
   result+=arguments.indices.contains(index) ? String(describing:arguments[index]):String(template[range])
   start=range.upperBound
  }
  result+=template[start...];return result
 }
 // Only use for product notices already stored in state. Never apply this to
 // nicknames, user messages, model answers or externally supplied session titles.
 func notice(_ text:String)->String {
  if let key=noticeKeys[text]{return render(key,arguments:[])}
  let full=NSRange(text.startIndex...,in:text)
  for template in noticeTemplates {
   guard let match=template.expression.firstMatch(in:text,range:full) else{continue}
   var arguments=[String](repeating:"",count:(template.positions.max() ?? -1)+1)
   for (capture,position) in template.positions.enumerated(){if let range=Range(match.range(at:capture+1),in:text){arguments[position]=String(text[range])}}
   return render(template.key,arguments:arguments)
  }
  return text
 }
 deinit{if let localeObserver{NotificationCenter.default.removeObserver(localeObserver)}}
}

enum L10n {
 static func text(_ key:String,_ arguments:Any...)->String{AppLocalization.shared.render(key,arguments:arguments)}
 static func notice(_ text:String)->String{AppLocalization.shared.notice(text)}
}
