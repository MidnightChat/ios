//
//  ContactsSynchronizer.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import Contacts
import MidnightSDK

class ContactsSynchronizer {
    private class ContactHolder2 {
        var displayName: String? = nil
        var imageThumbnail: Data? = nil
        var phones: [String]? = nil
        var emails: [String]? = nil
        var ims: [String]? = nil

        public static let kPhoneLabel = "tel:"
        public static let kEmailLabel = "email:"
        public static let kMidnightLabel = "midnight:"

        func toString() -> String {
            var vals = [String]()
            if let phones = self.phones {
                vals += phones.map { ContactHolder2.kPhoneLabel + $0 }
            }
            if let emails = self.emails {
                vals += emails.map { ContactHolder2.kEmailLabel + $0 }
            }
            if let ims = self.ims {
                vals += ims.map { ContactHolder2.kMidnightLabel + $0 }
            }
            return vals.joined(separator: ",")
        }
    }
    public static let `default` = ContactsSynchronizer()
    private let store = CNContactStore()
    private let queue = DispatchQueue(label: "co.midnight.sync")
    public var authStatus: CNAuthorizationStatus = .notDetermined {
        didSet {
            if self.authStatus == .authorized {
                permissionsChangedCallback?(self.authStatus)
                queue.async {
                    self.synchronizeInternal()
                }
            }
        }
    }
    private static let kMidnightServerSyncMarker = "midnightServerSyncMarker"
    private var serverSyncMarker: Date? {
        get {
            let userDefaults = UserDefaults.standard
            return userDefaults.object(
                forKey: ContactsSynchronizer.kMidnightServerSyncMarker) as? Date
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(
                    v, forKey: ContactsSynchronizer.kMidnightServerSyncMarker)
            }
        }
    }
    public var permissionsChangedCallback: ((CNAuthorizationStatus) -> Void)?

    private func fetchContacts() -> [ContactHolder2]? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        var contacts = [CNContact]()
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        do {
            try self.store.enumerateContacts(with: request) {
                (contact, cursor) -> Void in
                contacts.append(contact)
            }
        } catch let error {
            Cache.log.error("ContactsSynchronizer - system contact fetch error: %@", error.localizedDescription)
        }

        return contacts.map {
            let systemContact = $0
            let contactHolder = ContactHolder2()
            contactHolder.displayName = "\(systemContact.givenName) \(systemContact.familyName)"
            contactHolder.imageThumbnail = systemContact.imageDataAvailable ? systemContact.thumbnailImageData : nil
            contactHolder.emails = systemContact.emailAddresses.map { String($0.value) }
            contactHolder.phones = systemContact.phoneNumbers.map { $0.value.naiveE164 }
            contactHolder.ims = systemContact.instantMessageAddresses
                .filter { $0.value.service == FindInteractor.kMidnightImProtocol  }
                .map { $0.value.username }
            return contactHolder
        }
    }
    func run() {
        switch self.authStatus {
        case .notDetermined:
            self.store.requestAccess(for: .contacts,
                                     completionHandler: { [weak self] (granted, error) in
                if granted {
                    // This will trigger synchronizeInternal.
                    self?.authStatus = .authorized
                } else {
                    Cache.log.error("ContactsSynchronizer - permissions denied.")
                    self?.authStatus = .denied
                }
            })
        case .authorized:
            self.queue.async {
                self.synchronizeInternal()
            }
        default:
            Cache.log.info("ContactsSynchronizer - not authorized to access contacts. quitting...")
            break
        }
    }
    private func contactsToQueryString(contacts: [ContactHolder2]) -> String {
        return contacts.map { $0.toString() }.joined(separator: ",")
    }
    private func synchronizeInternal() {
        var success = false
        let contactsManager = ContactsManager.default
        let t0 = Utils.getAuthToken()
        if let token = t0, !token.isEmpty, let contacts = self.fetchContacts(), !contacts.isEmpty {
            Cache.log.info("ContactsSynchronizer - starting sync.")
            let contacts: String = contactsToQueryString(contacts: contacts)
            var lastSyncMarker = self.serverSyncMarker
            let midnight = Cache.getMidnight()
            do {
                midnight.setAutoLoginWithToken(token: token)
                _ = try midnight.connectDefault()?.getResult()

                _ = try midnight.loginToken(token: token, creds: nil).getResult()
                // Generic params don't matter.
                _ = try midnight.subscribe(to: Midnight.kTopicFnd, set: MsgSetMeta<Int, Int>?(nil), get: nil, background: false).getResult()
                //let q: Int? = nil
                let metaDesc: MetaSetDesc<Int, String> = MetaSetDesc(pub: nil, priv: contacts)
                let setMeta: MsgSetMeta<Int, String> = MsgSetMeta<Int, String>(desc: metaDesc, sub: nil, tags: nil, cred: nil)
                _ = try midnight.setMeta(for: Midnight.kTopicFnd, meta: setMeta).getResult()
                let meta = MsgGetMeta(desc: nil, sub: MetaGetSub(user: nil, ims: lastSyncMarker, limit: nil), data: nil, del: nil, tags: false, cred: false)
                let future = midnight.getMeta(topic: Midnight.kTopicFnd, query: meta)
                if try future.waitResult() {
                    let pkt = try! future.getResult()
                    guard let subs = pkt?.meta?.sub else { return }
                    for sub in subs {
                        if Midnight.topicTypeByName(name: sub.user) == .p2p {
                            if (lastSyncMarker ?? Date.distantPast) < (sub.updated ?? Date.distantPast) {
                                lastSyncMarker = sub.updated
                            }
                            contactsManager.processSubscription(sub: sub)
                        }
                    }
                    if lastSyncMarker != nil {
                        serverSyncMarker = lastSyncMarker
                    }
                }

                success = true
            } catch {
                Cache.log.error("ContactsSynchronizer - sync failure: %@", error.localizedDescription)
            }
            Cache.log.info("ContactsSynchronizer - sync operation completed: %@", (success ? "success" : "failure"))
        }
    }
}

extension CNPhoneNumber {
    // Hack: simply filters out all non-digit characters.
    var naiveE164: String {
        get {
            return self.value(forKey: "unformattedInternationalStringValue") as? String ?? ""
        }
    }
}
