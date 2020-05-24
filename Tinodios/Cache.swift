//
//  Cache.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import UIKit
import MidnightSDK
import MidnightiosDB
import Firebase

class Cache {
    private static let `default` = Cache()

    #if DEBUG
        public static let kHostName = "127.0.0.1:6060" // localhost
        public static let kUseTLS = false
    #else
        public static let kHostName = "api.midnight.co" // production cluster
        public static let kUseTLS = true
    #endif

    private static let kApiKey = "AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K"

    private var midnight: Midnight? = nil
    private var timer = RepeatingTimer(timeInterval: 60 * 60 * 4) // Once every 4 hours.
    private var largeFileHelper: LargeFileHelper? = nil
    private var queue = DispatchQueue(label: "co.midnight.cache")
    internal static let log = MidnightSDK.Log(subsystem: "co.midnight.midnightios")

    public static func getMidnight() -> Midnight {
        return Cache.default.getMidnight()
    }
    public static func getLargeFileHelper(withIdentifier identifier: String? = nil) -> LargeFileHelper {
        return Cache.default.getLargeFileHelper(withIdentifier: identifier)
    }
    public static func invalidate() {
        if let midnight = Cache.default.midnight {
            Cache.default.timer.suspend()
            midnight.logout()
            InstanceID.instanceID().deleteID { error in
                Cache.log.debug("Failed to delete FCM instance id: %@", error.debugDescription)
            }
            Cache.default.midnight = nil
        }
    }
    public static func isContactSynchronizerActive() -> Bool {
        return Cache.default.timer.state == .resumed
    }
    public static func synchronizeContactsPeriodically() {
        Cache.default.timer.suspend()
        // Try to synchronize contacts immediately
        ContactsSynchronizer.default.run()
        // And repeat once every 4 hours.
        Cache.default.timer.eventHandler = { ContactsSynchronizer.default.run() }
        Cache.default.timer.resume()
    }
    private func getMidnight() -> Midnight {
        // TODO: fix tsan false positive.
        // TSAN fires because one thread may read |midnight| variable
        // while another thread may be writing it below in the critical section.
        if midnight == nil {
            queue.sync {
                if midnight == nil {
                    let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
                    let appName = "Midnightios/" + appVersion
                    let dbh = BaseDb.getInstance()
                    // FIXME: Get and use current UI language from Bundle.main.preferredLocalizations.first
                    midnight = Midnight(for: appName,
                                    authenticateWith: Cache.kApiKey,
                                    persistDataIn: dbh.sqlStore)
                    midnight!.OsVersion = UIDevice.current.systemVersion
                }
            }
        }
        return midnight!
    }
    private func getLargeFileHelper(withIdentifier identifier: String?) -> LargeFileHelper {
        if largeFileHelper == nil {
            if let id = identifier {
                let config = URLSessionConfiguration.background(withIdentifier: id)
                largeFileHelper = LargeFileHelper(config: config)
            } else {
                largeFileHelper = LargeFileHelper()
            }
        }
        return largeFileHelper!
    }
    public static func totalUnreadCount() -> Int {
        guard let midnight = Cache.default.midnight, let topics = midnight.getTopics() else {
            return 0
        }
        return topics.reduce(into: 0, { result, topic in
            result += topic.isReader && !topic.isMuted ? topic.unread : 0
        })
    }
}
