// Decode the actual shared notification/Codable envelope only; no notification is posted. — GPT-6.1 Sol
import Foundation
@main enum HelloChatYouTubeVolumeContractTests {
 static func main() throws {
  var checks=0
  func check(_ value:Bool,_ message:String) { precondition(value,message);checks += 1 }
  let id=UUID().uuidString,now=BridgeNotification.now()
  func decode(_ value:Any)->HelloChatVideoNotification.Request? {
   HelloChatVideoNotification.decodeRequest(Notification(name:HelloChatVideoNotification.request,userInfo:["requestId":id,"action":"setVolume","issuedAt":now,"volumePercent":value]))
  }
  for value in 0...100 { check(decode(value)?.volumePercent==value,"Integer percentage") }
  for value:Any in [-1,101,30.5,true,"30",NSNull(),Double.nan,Double.infinity] { check(decode(value)==nil,"Invalid percentage refused") }
  for action in ["pause","play"] {
   let request=HelloChatVideoNotification.decodeRequest(Notification(name:HelloChatVideoNotification.request,userInfo:["requestId":id,"action":action,"issuedAt":now]))
   check(request?.action.rawValue==action && request?.volumePercent==nil,"Old directional envelope stays compatible")
  }
  var message=BridgeMessage(type:"hellochat-video-result");message.requestId=id;message.videoAction="setVolume";message.protocolVersion=1
  message.volumePercent=30;message.confirmed=true;message.changed=false;message.playing=false;message.paused=true;message.muted=true
  let decoded=try JSONDecoder().decode(BridgeMessage.self,from:JSONEncoder().encode(message))
  check(decoded.volumePercent==30 && decoded.confirmed==true && decoded.muted==true,"Exact result fields survive native Codable relay")
  check(HelloChatVideoNotification.isFresh(issuedAt:now-2500,now:now),"Existing inclusive native window")
  check(!HelloChatVideoNotification.isFresh(issuedAt:now-2501,now:now),"No enlarged request lifetime")
  print("Actual shared YouTube absolute-volume contract: \(checks) checks passed")
 }
}
