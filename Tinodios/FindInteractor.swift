//
//  FindInteractor.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import MidnightSDK

protocol FindBusinessLogic: class {
    var fndTopic: DefaultFndTopic? { get }
    func loadAndPresentContacts(searchQuery: String?)
    func updateAndPresentRemoteContacts()
    func saveRemoteTopic(from remoteContact: RemoteContactHolder) -> Bool
    func setup()
    func cleanup()
    func attachToFndTopic()
}

class RemoteContactHolder: ContactHolder {
    var sub: Subscription<VCard, Array<String>>? = nil
}

class FindInteractor: FindBusinessLogic {
    private class FndListener: DefaultFndTopic.Listener {
        weak var interactor: FindBusinessLogic?
        override func onMetaSub(sub: Subscription<VCard, Array<String>>) {
            // bitmaps?
        }
        override func onSubsUpdated() {
            self.interactor?.updateAndPresentRemoteContacts()
        }
    }

    static let kMidnightImProtocol = "Midnight"
    var presenter: FindPresentationLogic?
    private var queue = DispatchQueue(label: "co.midnight.contacts")
    // All known contacts from BaseDb's Users table.
    private var localContacts: [ContactHolder]?
    // Current search query (nil if none).
    private var searchQuery: String?
    var fndTopic: DefaultFndTopic?
    private var fndListener: FindInteractor.FndListener?
    // Contacts returned by the server
    // in response to a search request.
    private var remoteContacts: [RemoteContactHolder]?
    private var contactsManager = ContactsManager()

    func setup() {
        fndListener = FindInteractor.FndListener()
        fndListener?.interactor = self
    }
    func cleanup() {
        fndTopic?.listener = nil
        if fndTopic?.attached ?? false {
            fndTopic?.leave()
        }
    }
    func attachToFndTopic() {
        let midnight = Cache.getMidnight()
        UiUtils.attachToFndTopic(fndListener: self.fndListener)?.then(
                onSuccess: { [weak self] msg in
                    self?.fndTopic = midnight.getOrCreateFndTopic()
                    return nil
                },
                onFailure: { err in
                    Cache.log.error("FindInteractor - failed to attach to fnd topic: %@", err.localizedDescription)
                    return nil
                })

    }
    func updateAndPresentRemoteContacts() {
        if let subs = fndTopic?.getSubscriptions(), !(searchQuery?.isEmpty ?? true) {
            self.remoteContacts = subs.map { sub in
                let contact = RemoteContactHolder(displayName: sub.pub?.fn, image: sub.pub?.photo?.image(), uniqueId: sub.uniqueId, subtitle: sub.priv?.joined(separator: ", "))
                contact.sub = sub
                return contact
            }
        } else {
            self.remoteContacts?.removeAll()
        }
        self.presenter?.presentRemoteContacts(contacts: self.remoteContacts!)
    }

    func loadAndPresentContacts(searchQuery: String? = nil) {
        let changed = self.searchQuery != searchQuery
        self.searchQuery = searchQuery
        queue.async {
            if self.localContacts == nil {
                self.localContacts = self.contactsManager.fetchContacts() ?? []
            }
            if self.remoteContacts == nil {
               self.remoteContacts = []
            }
            let contacts: [ContactHolder] =
                self.searchQuery != nil ?
                    self.localContacts!.filter { u in
                        guard let displayName = u.displayName else { return false }
                        guard let r = displayName.range(of: self.searchQuery!, options: .caseInsensitive) else {return false}
                        return r.contains(displayName.startIndex)
                    } :
                    self.localContacts!
            if changed {
                self.fndTopic?.setMeta(meta: MsgSetMeta(desc: MetaSetDesc(pub: searchQuery != nil ? searchQuery! : Midnight.kNullValue, priv: nil), sub: nil, tags: nil, cred: nil))
            }
            self.remoteContacts?.removeAll()
            if let queryString = searchQuery, queryString.count >= UiUtils.kMinTagLength {
                self.fndTopic?.getMeta(query: MsgGetMeta.sub())
            } else {
                // Clear remoteContacts.
                self.presenter?.presentRemoteContacts(contacts: self.remoteContacts!)
            }
            self.presenter?.presentLocalContacts(contacts: contacts)
        }
    }

    func saveRemoteTopic(from remoteContact: RemoteContactHolder) -> Bool {
        guard let topicName = remoteContact.uniqueId, let sub = remoteContact.sub else {
            return false
        }
        let midnight = Cache.getMidnight()
        var topic: DefaultComTopic?
        if !midnight.isTopicTracked(topicName: topicName) {
            topic = midnight.newTopic(for: topicName) as? DefaultComTopic
            topic?.pub = sub.pub
            topic?.persist(true)
        } else {
            topic = midnight.getTopic(topicName: topicName) as? DefaultComTopic
        }
        guard let topicUnwrapped = topic else { return false }
        if topicUnwrapped.isP2PType {
            contactsManager.processSubscription(sub: sub)
        }
        return true
    }
}
