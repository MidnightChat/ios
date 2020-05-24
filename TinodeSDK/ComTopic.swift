//
//  ComTopic.swift
//  MidnightSDK
//
//  Copyright © 2020 Midnight. All rights reserved.
//

import Foundation

public class ComTopic<DP: Codable & Mergeable>: Topic<DP, PrivateType, DP, PrivateType> {
    override init(midnight: Midnight?, name: String, l: Listener?) {
        super.init(midnight: midnight, name: name, l: l)
    }
    override init(midnight: Midnight?, sub: Subscription<DP, PrivateType>) {
        super.init(midnight: midnight, sub: sub)
    }
    override init(midnight: Midnight?, name: String, desc: Description<DP, PrivateType>) {
        super.init(midnight: midnight, name: name, desc: desc)
    }
    public convenience init(in midnight: Midnight?, forwardingEventsTo l: Listener? = nil) {
        self.init(midnight: midnight!, name: Midnight.kTopicNew + midnight!.nextUniqueString(), l: l)
    }

    public override var isArchived: Bool {
        guard let archived = priv?["arch"] else { return false }
        switch archived {
        case .bool(let x):
            return x
        default:
            return false
        }
    }

    public var comment: String? {
        return priv?.comment
    }

    public var peer: Subscription<DP, PrivateType>? {
        guard isP2PType else { return nil }
        return self.getSubscription(for: self.name)
    }

    override public func getSubscription(for key: String?) -> Subscription<DP, PrivateType>? {
        guard let sub = super.getSubscription(for: key) else { return nil }
        if isP2PType && sub.pub == nil {
            sub.pub = self.name == key ? self.pub : midnight?.getMeTopic()?.pub as? DP
        }
        return sub
    }

    public func updateArchived(archived: Bool) -> PromisedReply<ServerMessage>? {
        var priv = PrivateType()
        priv.archived = archived
        let meta = MsgSetMeta<DP, PrivateType>(
            desc: MetaSetDesc(pub: nil, priv: priv),
            sub: nil,
            tags: nil,
            cred: nil)
        return setMeta(meta: meta)
    }
}
