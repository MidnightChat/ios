//
//  CredentialsViewController.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import UIKit
import MidnightSDK

class CredentialsViewController : UIViewController {

    @IBOutlet weak var codeText: UITextField!

    var meth: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 12.0, *), traitCollection.userInterfaceStyle == .dark {
            self.view.backgroundColor = .black
        } else {
            self.view.backgroundColor = .white
        }

        UiUtils.dismissKeyboardForTaps(onView: self.view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isMovingFromParent {
            // If the user's logged in and is voluntarily leaving the verification VC
            // by hitting the Back button.
            let midnight = Cache.getMidnight()
            if midnight.isConnectionAuthenticated || midnight.myUid != nil {
                midnight.logout()
            }
        }
    }

    @IBAction func onConfirm(_ sender: UIButton) {
        guard let code = codeText.text else {
            return
        }
        guard let method = meth else {
            return
        }

        let midnight = Cache.getMidnight()

        guard let token = midnight.authToken else {
            self.dismiss(animated: true, completion: nil)
            return
        }

        let c = Credential(meth: method, val: nil, resp: code, params: nil)
        var creds = [Credential]()
        creds.append(c)

        midnight.loginToken(token: token, creds: creds)
            .thenApply({ msg in
                if let ctrl = msg?.ctrl, ctrl.code >= 300 {
                    DispatchQueue.main.async {
                        UiUtils.showToast(message: String(format: NSLocalizedString("Verification failure: %d %@", comment: "Error message"), ctrl.code, ctrl.text))
                    }
                } else {
                    if let token = midnight.authToken {
                        midnight.setAutoLoginWithToken(token: token)
                    }
                    UiUtils.routeToChatListVC()
                }
                return nil
            })
    }
}
