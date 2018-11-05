//
//  UserManager.swift
//  ZebraKing
//
//  Created by 武飞跃 on 2017/9/11.
//  Copyright © 2017年 武飞跃. All rights reserved.
//
import Foundation
import ImSDK
import IMMessageExt

public struct ChatNotification {
    public let receiver: Sender
    public let content: String?
    public let unreadCount: Int
}


//MARK: - 会话中心管理
open class CentralManager: NSObject {
    
    public typealias CountCompletion = (Int) -> Void
    
    internal private(set) var conversationList = Set<Conversation>()
    
    // 监听消息通知
    private var onResponseNotification = Set<NotifiableMessages>()
    private var unReadCountCompletion: CountCompletion?
    
    //当前聊天的对象
    private var chattingConversation: Conversation? {
        didSet {
            guard chattingConversation != nil else { return }
            unReadCountCompletion?(0)
        }
    }
    
    //处于会话页面时, 是否将通知来的消息, 自动设置为已读
    public var isAutoDidReadedWhenReceivedMessage: Bool = true
    
    /// 主动触发聊天
    ///
    /// - Parameters:
    ///   - type: 聊天类型  单人或群组
    ///   - id: 房间号
    /// - Returns: 会话对象
    public func holdChat(with type: TIMConversationType, id: String) -> Conversation? {
        let wrappedConversation = conversation(with: type, id: id)
        chattingConversation = wrappedConversation
        return chattingConversation
    }
    
    
    /// 主动释放聊天
    public func waiveChat() {
        //这里需
        chattingConversation?.free()
        chattingConversation = nil
    }
    
    /// 移除会话
    public func deleteConversation(where rule: (Conversation) throws -> Bool) rethrows {
        guard let conversation = try conversationList.first(where: rule) else { return }
        conversation.delete(with: .C2C)
        conversationList.remove(conversation)
    }
    
    /// 从集合中获取指定会话(如果集合中不存在,才会创建一个)
    ///
    /// - Parameters:
    ///   - type: 会话类型  c2c 群消息 系统消息
    ///   - id: 会话id
    /// - Returns: 返回一个会话任务
    private func conversation(with type: TIMConversationType, id: String) -> Conversation? {
        
        if let targetConversation = conversationList.first(where: { $0.receiverId == id && $0.type == type }) {
            return targetConversation
        }
        
        if let targetConversation = Conversation(type: type, id: id) {
            conversationList.insert(targetConversation)
            return targetConversation
        }
        
        return nil
    }
    
    public func removeListenter(id: String) {
        //FIXME: 移除消息监听, 后期要改成通知监听的模式
        if id.isEmpty {
            onResponseNotification.forEach({
                if $0.identifier != "outsideNotification" {
                    $0.free()
                    onResponseNotification.remove($0)
                }
            })
        }
        
        guard let listenerMessages = onResponseNotification.first(where: { $0.identifier == id }) else {
            return
        }
        listenerMessages.free()
        onResponseNotification.remove(listenerMessages)
    }
    
}

//MARK: - 未读消息
extension CentralManager {
    
    internal func addListenter() {
        TIMManager.sharedInstance().add(self)
    }
    
    /// 监听消息通知
    internal func listenterMessages(completion: @escaping NotifiableMessages.Completion) {
        onResponseNotification.insert(NotifiableMessages(identifier: "outsideNotification", completion: completion))
    }
    
    internal func removeListener() {
        TIMManager.sharedInstance()?.remove(self)
    }
    
    //根据会话类型监听此会话的未读消息数
    public func listenerUnReadCount(with type: TIMConversationType, id: String, completion:@escaping CountCompletion) {
        
        let unreadCount = conversation(with: type, id: id)?.unreadMessageCount ?? 0
        
        completion(unreadCount)
        
        DispatchQueue.main.async {
            self.unReadCountCompletion = completion
        }
        
//
//        let listenter = NotifiableMessages(identifier: id, completion: { (_, _, unreadCount) in
//            DispatchQueue.main.async { completion(unreadCount) }
//        })
//
//        listenter.completion?("", nil, unreadCount)
//
//        onResponseNotification.insert(listenter)
    }
    
}

extension CentralManager: TIMMessageListener {
    
    public func onNewMessage(_ msgs: [Any]!) {
        
        for anyObjcet in msgs {
            
            guard let message = anyObjcet as? TIMMessage,
                let timConversation = message.getConversation() else { return }
            
            //局部对象, 作用域仅在此方法内, 注意会调用deinit
            let conversation = Conversation(conversation: timConversation)
            
            //此会话是否存在聊天列表中
            if let didExistingConversation = conversationList.first(where: { $0 == conversation }) {
                
                didExistingConversation.onReceiveMessageCompletion?(message)
                
                //正处于当前活跃的会话页面时,将消息设置为已读
                if didExistingConversation == chattingConversation && isAutoDidReadedWhenReceivedMessage {
                    chattingConversation?.alreadyRead(message: message)
                    return
                }
                
                if message.isSelf() == false {
                    //列表中,别的会话发过来的消息, 就给个通知
                    handlerNotification(with: conversation)
                }

            }
            else {
                //新的会话不在列表中,可能是对方先发起的聊天,需要插入到会话列表中
                conversationList.insert(conversation)
                handlerNotification(with: conversation)
            }
            
        }
    }
    
    private func handlerNotification(with conversation: Conversation) {
        
        //仅支持C2C通知
        guard conversation.type == .C2C else { return }
        
        let content = conversation.getLastMessage
        let receiverId = conversation.receiverId
        let unreadCount = conversation.unreadMessageCount
        
        onResponseNotification.forEach{ $0.send(receiverId, content, unreadCount) }
        
        unReadCountCompletion?(unreadCount)
        
    }

}

public final class NotifiableMessages {
    
    public typealias Completion = (_ receiverID: String, _ content: String?, _ unreadCount: Int) -> Void
    
    let identifier: String
    var completion: Completion?
    
    init(identifier: String, completion: @escaping Completion) {
        self.identifier = identifier
        self.completion = completion
    }
    
    func emptySignl() {
        completion?("", nil, 0)
    }
    
    func free() {
        if completion != nil {
            completion = nil
        }
    }
    
    func send(_ receiverID: String, _ content: String?, _ unreadCount: Int) {
        DispatchQueue.main.async {
            self.completion?(receiverID, content, unreadCount)
        }
    }
}

extension NotifiableMessages: Hashable {
    
    public var hashValue: Int {
        return identifier.hashValue
    }
    
    public static func == (lhs: NotifiableMessages, rhs: NotifiableMessages) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}

