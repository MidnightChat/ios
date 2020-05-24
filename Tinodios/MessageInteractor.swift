//
//  MessageInteractor.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import MidnightSDK
import MidnightiosDB

protocol MessageBusinessLogic: class {
    @discardableResult
    func setup(topicName: String?) -> Bool
    @discardableResult
    func attachToTopic(interactively: Bool) -> Bool
    func cleanup()
    func leaveTopic()

    func sendMessage(content: Drafty)
    func sendReadNotification(explicitSeq: Int?, when deadline: DispatchTime)
    func sendTypingNotification()
    func enablePeersMessaging()
    func acceptInvitation()
    func ignoreInvitation()
    func blockTopic()
    func uploadFile(filename: String?, refurl: URL?, mimeType: String?, data: Data?)
}

protocol MessageDataStore {
    var topicName: String? { get set }
    var topic: DefaultComTopic? { get set }
    @discardableResult
    func setup(topicName: String?) -> Bool
    func loadMessages()
    func loadNextPage()
    func deleteMessage(seqId: Int)
} 

class MessageInteractor: DefaultComTopic.Listener, MessageBusinessLogic, MessageDataStore {
    class MessageEventListener: UiMidnightEventListener {
        private weak var interactor: MessageBusinessLogic?
        init(interactor: MessageBusinessLogic?, connected: Bool) {
            super.init(connected: connected)
            self.interactor = interactor
        }
        override func onLogin(code: Int, text: String) {
            super.onLogin(code: code, text: text)
            _ = UiUtils.attachToMeTopic(meListener: nil)
            _ = interactor?.attachToTopic(interactively: false)
        }
    }
    static let kMessagesPerPage = 24
    var pagesToLoad: Int = 0
    var topicId: Int64?
    var topicName: String?
    var topic: DefaultComTopic?
    var presenter: MessagePresentationLogic?
    var messages: [StoredMessage] = []
    private var messageInteractorQueue = DispatchQueue(label: "co.midnight.messageinteractor")
    private var midnightEventListener: MessageEventListener? = nil
    // Last reported recv and read seq ids by the onInfo handler.
    // Upon receipt of an info message, the handler will reload all messages with
    // seq ids between the last seen seq id (for recv and read messages respectively)
    // and the reported info.seq.
    // The new value for the variables below will be updated to info.seq.
    private var lastSeenRecv: Int?
    private var lastSeenRead: Int?

    // How many read notifications are currently scheduled to be sent.
    private var readNotificationsInFlight = 0

    @discardableResult
    func setup(topicName: String?) -> Bool {
        guard let topicName = topicName else { return false }
        self.topicName = topicName
        self.topicId = BaseDb.getInstance().topicDb?.getId(topic: topicName)
        let midnight = Cache.getMidnight()
        if self.midnightEventListener == nil {
            self.midnightEventListener = MessageEventListener(
                interactor: self,
                connected: midnight.isConnected)
        }
        midnight.addListener(self.midnightEventListener!)
        self.topic = midnight.getTopic(topicName: topicName) as? DefaultComTopic
        self.pagesToLoad = 1

        if let pub = self.topic?.pub {
            self.presenter?.updateTitleBar(icon: pub.photo?.image(), title: pub.fn, online: self.topic?.online ?? false)
        }
        self.lastSeenRead = self.topic?.read
        self.lastSeenRecv = self.topic?.recv
        self.topic?.listener = self
        return self.topic != nil
    }
    func cleanup() {
        // set listeners to nil
        if self.topic?.listener === self {
            self.topic?.listener = nil
        }
        let midnight = Cache.getMidnight()
        if let listener = self.midnightEventListener {
            midnight.removeListener(listener)
        }
    }
    func leaveTopic() {
        if self.topic?.attached ?? false {
            self.topic?.leave()
        }
    }
    func attachToTopic(interactively: Bool) -> Bool {
        guard let topic = self.topic, !topic.attached else {
            self.presenter?.applyTopicPermissions(withError: nil)
            return true
        }
        let midnight = Cache.getMidnight()
        guard midnight.isConnectionAuthenticated else {
            // If connection is not ready, wait for completion.
            // MessageInteractor.attachToTopic() will be called again from the onLogin callback.
            midnight.reconnectNow(interactively: interactively, reset: false)
            return false
        }
        var builder = topic.metaGetBuilder()
            .withDesc()
            .withSub()
            .withLaterData(limit: MessageInteractor.kMessagesPerPage)
            .withDel()
        if topic.isOwner {
            builder = builder.withTags()
        }
        topic.subscribe(set: nil, get: builder.build()).then(
                onSuccess: { [weak self] _ in
                    self?.messageInteractorQueue.async {
                        self?.topic?.syncAll().then(
                            onSuccess: { [weak self] _ in
                                self?.loadMessages()
                                return nil
                            },
                            onFailure: { err in
                                Cache.log.error("MessageInteractor - Failed to send pending messages: %@", err.localizedDescription)
                                return nil
                            }
                        )
                    }
                    if self?.topicId == -1 {
                        self?.topicId = BaseDb.getInstance().topicDb?.getId(topic: self?.topicName)
                    }
                    self?.loadMessages()
                    self?.presenter?.applyTopicPermissions(withError: nil)
                    return nil
                },
                onFailure: { [weak self] err in
                    let midnight = Cache.getMidnight()
                    let errorMsg = String(format: NSLocalizedString("Failed to subscribe to topic: %@", comment: "Error message"), err.localizedDescription)
                    if midnight.isConnected {
                        DispatchQueue.main.async {
                            UiUtils.showToast(message: errorMsg)
                        }
                    } else {
                        Cache.log.error("MessageInteractor: %@", errorMsg)
                    }
                    switch err {
                    case MidnightError.notConnected(_):
                        midnight.reconnectNow(interactively: false, reset: false)
                    default:
                        self?.presenter?.applyTopicPermissions(withError: err)
                    }
                    return nil
                })

        return false
    }

    func sendMessage(content: Drafty) {
        guard let topic = self.topic else { return }
        defer {
            loadMessages()
        }
        topic.publish(content: content).then(
            onSuccess: { [weak self] msg in
                self?.loadMessages()
                return nil
            },
            onFailure: { err in
                Cache.log.error("sendMessage error: %@", err.localizedDescription)
                if let e = err as? MidnightError {
                    switch e {
                    case .notConnected(_):
                        DispatchQueue.main.async { UiUtils.showToast(message: NSLocalizedString("You are offline.", comment: "Toast notification")) }
                        Cache.getMidnight().reconnectNow(interactively: false, reset: false)
                    default:
                        DispatchQueue.main.async { UiUtils.showToast(message: NSLocalizedString("Message not sent.", comment: "Toast notification")) }
                    }
                }
                return nil
            }
        )
    }
    func sendReadNotification(explicitSeq: Int? = nil, when deadline: DispatchTime) {
        readNotificationsInFlight += 1
        messageInteractorQueue.asyncAfter(deadline: deadline) { [weak self] in
            // Don't send a notification if more notifications are pending. This avoids the case of acking
            // every {data} message in a large batch.
            // It may pose a problem if a later message is acked first (msg[1].seq > msg[2].seq), but that
            // should not happen.
            if self?.readNotificationsInFlight == 1 {
                self?.topic?.noteRead(explicitSeq: explicitSeq)
            }
            self?.readNotificationsInFlight -= 1
        }
    }
    func sendTypingNotification() {
        topic?.noteKeyPress()
    }

    func loadMessages() {
        self.messageInteractorQueue.async {
            if let messages = BaseDb.getInstance().messageDb?.query(
                    topicId: self.topicId,
                    pageCount: self.pagesToLoad,
                    pageSize: MessageInteractor.kMessagesPerPage) {
                self.messages = messages
                self.presenter?.presentMessages(messages: messages)
            }
        }
    }

    private func loadNextPageInternal() -> Bool {
        if self.pagesToLoad * MessageInteractor.kMessagesPerPage == self.messages.count {
            self.pagesToLoad += 1
            self.loadMessages()
            return true
        }
        return false
    }

    func loadNextPage() {
        guard let t = self.topic else {
            self.presenter?.endRefresh()
            return
        }
        if !loadNextPageInternal() && !StoredTopic.isAllDataLoaded(topic: t) {
            t.getMeta(query:t.metaGetBuilder()
                .withEarlierData(limit: MessageInteractor.kMessagesPerPage).build())
                .thenFinally({ [weak self] in
                    self?.presenter?.endRefresh()
                })
        } else {
            self.presenter?.endRefresh()
        }
    }
    func deleteMessage(seqId: Int) {
        topic?.delMessage(id: seqId, hard: false).then(
            onSuccess: { [weak self] msg in
                self?.loadMessages()
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler)
        self.loadMessages()
    }

    func enablePeersMessaging() {
        // Enable peer.
        guard let origAm = self.topic?.getSubscription(for: self.topic?.name)?.acs else { return }
        let am = Acs(from: origAm)
        guard am.given?.update(from: "+RW") ?? false else {
            return
        }
        topic?.setMeta(meta: MsgSetMeta(desc: nil, sub: MetaSetSub(user: topic?.name, mode: am.givenString), tags: nil, cred: nil)).thenCatch(UiUtils.ToastFailureHandler)
    }

    func acceptInvitation() {
        guard let topic = self.topic, let mode = self.topic?.accessMode?.givenString else { return }
        var response = topic.setMeta(meta: MsgSetMeta(desc: nil, sub: MetaSetSub(mode: mode), tags: nil, cred: nil))
        if topic.isP2PType {
            // For P2P topics change 'given' permission of the peer too.
            // In p2p topics the other user has the same name as the topic.
            response = response.then(
                onSuccess: { msg in
                    _ = topic.setMeta(meta: MsgSetMeta(
                        desc: nil,
                        sub: MetaSetSub(user: topic.name, mode: mode),
                        tags: nil,
                        cred: nil))
                    return nil
                },
                onFailure: UiUtils.ToastFailureHandler
            )
        }
        response.thenApply({ msg in
            self.presenter?.applyTopicPermissions(withError: nil)
            return nil
        })
    }
    func ignoreInvitation() {
        self.topic?.delete(hard: true)
            .thenFinally({
                self.presenter?.dismiss()
            })
    }

    func blockTopic() {
        guard let origAm = self.topic?.accessMode else { return }
        let am = Acs(from: origAm)
        guard am.want?.update(from: "-JP") ?? false else { return }
        self.topic?.setMeta(meta: MsgSetMeta(desc: nil, sub: MetaSetSub(mode: am.wantString), tags: nil, cred: nil))
            .thenCatch(UiUtils.ToastFailureHandler)
            .thenFinally({
                self.presenter?.dismiss()
            })
    }

    static private func existingInteractor(for topicName: String?) -> MessageInteractor? {
        // Must be called on main thread.
        guard let topicName = topicName else { return nil }
        guard let window = UIApplication.shared.keyWindow, let navVC = window.rootViewController as? UINavigationController else {
            return nil
        }
        for controller in navVC.viewControllers {
            if let messageVC = controller as? MessageViewController, messageVC.topicName == topicName {
                return messageVC.interactor as? MessageInteractor
            }
        }
        return nil
    }

    func uploadFile(filename: String?, refurl: URL?, mimeType: String?, data: Data?) {
        guard let filename = filename, let mimeType = mimeType, let data = data, let topic = topic else { return }
        guard let content = try? Drafty().attachFile(mime: mimeType,
                                                bits: nil,
                                                fname: filename,
                                                refurl: refurl,
                                                size: data.count) else { return }
        if let msgId = topic.store?.msgDraft(topic: topic, data: content, head: Midnight.draftyHeaders(for: content)) {
            let helper = Cache.getLargeFileHelper()
            helper.startUpload(
                filename: filename, mimetype: mimeType, d: data,
                topicId: self.topicName!, msgId: msgId,
                progressCallback: { [weak self] progress in
                    let interactor = self ?? MessageInteractor.existingInteractor(for: topic.name)
                    interactor?.presenter?.updateProgress(forMsgId: msgId, progress: progress)
                },
                completionCallback: { [weak self] (serverMessage, error) in
                    let interactor = self ?? MessageInteractor.existingInteractor(for: topic.name)
                    var success = false
                    defer {
                        if !success {
                            _ = topic.store?.msgDiscard(topic: topic, dbMessageId: msgId)
                        }
                        interactor?.loadMessages()
                    }
                    guard error == nil else {
                        DispatchQueue.main.async {
                            UiUtils.showToast(message: error!.localizedDescription)
                        }
                        return
                    }
                    guard let ctrl = serverMessage?.ctrl, ctrl.code == 200, let serverUrl = ctrl.getStringParam(for: "url") else {
                        return
                    }
                    if let srvUrl = URL(string: serverUrl), let content = try? Drafty().attachFile(
                        mime: mimeType, fname: filename,
                        refurl: srvUrl, size: data.count) {
                        _ = topic.store?.msgReady(topic: topic, dbMessageId: msgId, data: content)
                        topic.syncOne(msgId: msgId)
                            .thenFinally({
                                interactor?.loadMessages()
                            })
                        success = true
                    }
                })
            self.loadMessages()
        }
    }
    override func onData(data: MsgServerData?) {
        self.loadMessages()
        if let from = data?.from, let seq = data?.seq, !Cache.getMidnight().isMe(uid: from) {
            sendReadNotification(explicitSeq: seq, when: .now() + .seconds(1))
        }
    }
    override func onPres(pres: MsgServerPres) {
        self.presenter?.applyTopicPermissions(withError: nil)
    }
    override func onOnline(online: Bool) {
        self.presenter?.setOnline(online: online)
    }
    override func onInfo(info: MsgServerInfo) {
        switch info.what {
        case "kp":
            self.presenter?.runTypingAnimation()
        case "recv":
            if let oldRecv = self.lastSeenRecv {
                if let newRecv = info.seq, oldRecv < newRecv {
                    self.presenter?.reloadMessages(fromSeqId: oldRecv + 1, toSeqId: newRecv)
                    self.lastSeenRecv = newRecv
                }
            } else {
                self.lastSeenRead = info.seq
                self.presenter?.reloadAllMessages()
            }
        case "read":
            if let oldRead = self.lastSeenRead {
                if let newRead = info.seq, oldRead < newRead {
                    self.presenter?.reloadMessages(fromSeqId: oldRead + 1, toSeqId: newRead)
                    self.lastSeenRead = newRead
                }
            } else {
                self.lastSeenRead = info.seq
                self.presenter?.reloadAllMessages()
            }
        default:
            break
        }
    }
    override func onSubsUpdated() {
        self.presenter?.applyTopicPermissions(withError: nil)
    }
    override func onMetaDesc(desc: Description<VCard, PrivateType>) {
        self.presenter?.applyTopicPermissions(withError: nil)
        if let pub = topic?.pub {
            self.presenter?.updateTitleBar(icon: pub.photo?.image(), title: pub.fn, online: self.topic?.online ?? false)
        }
    }
}
