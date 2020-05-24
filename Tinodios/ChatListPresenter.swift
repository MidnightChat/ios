//
//  ChatListPresenter.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import MidnightSDK

protocol ChatListPresentationLogic {
    func presentTopics(_ topics: [DefaultComTopic], archivedTopics: [DefaultComTopic]?)
    func topicUpdated(_ name: String)
    func topicDeleted(_ name: String)
}

class ChatListPresenter: ChatListPresentationLogic {
    weak var viewController: ChatListDisplayLogic?

    func presentTopics(_ topics: [DefaultComTopic], archivedTopics: [DefaultComTopic]?) {
        DispatchQueue.main.async {
            self.viewController?.displayChats(topics, archivedTopics: archivedTopics)
        }
    }

    func topicUpdated(_ name: String) {
        DispatchQueue.main.async {
            self.viewController?.updateChat(name)
        }
    }

    func topicDeleted(_ name: String) {
        DispatchQueue.main.async {
            self.viewController?.deleteChat(name)
        }
    }
}
