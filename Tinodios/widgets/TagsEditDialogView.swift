//
//  TagsEditDialogView.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import UIKit

class TagsEditDialogViewController: UIViewController {
    private static let kButtonBorderColor = UIColor(fromHexCode: 0xFFE0E0E0)

    public typealias CompletionHandler = ((_ newTags: [MidnightTag]) -> ())

    @IBOutlet weak var alertView: UIView!
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    @IBOutlet weak var tagsEditView: TagsEditView!
    private var initialTags: [MidnightTag] = []
    public var completionHandler: CompletionHandler?

    init(with tags: [MidnightTag]) {
        super.init(nibName: nil, bundle: nil)
        modalTransitionStyle = .crossDissolve
        modalPresentationStyle = .overCurrentContext

        self.initialTags = tags
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        cancelButton.addBorder(side: .top, color: TagsEditDialogViewController.kButtonBorderColor, width: 1)
        cancelButton.addBorder(side: .right, color: TagsEditDialogViewController.kButtonBorderColor, width: 1)
        okButton.addBorder(side: .top, color: TagsEditDialogViewController.kButtonBorderColor, width: 1)

        tagsEditView.fontSize = 17
        tagsEditView.onVerifyTag = { (_, tag) in
            return Utils.isValidTag(tag: tag)
        }
        tagsEditView.addTags(initialTags)
    }

    func show(over viewController: UIViewController?) {
        guard let viewController = viewController else { return }
        viewController.present(self, animated: true, completion: nil)
    }

    /// MARK: - Button clicks
    @IBAction func cancelClicked(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func okayClicked(_ sender: Any) {
        print("okay clicked")
        let newTags = tagsEditView.tags
        if !newTags.elementsEqual(initialTags) {
            completionHandler?(newTags)
        }
        self.dismiss(animated: true, completion: nil)
    }
}
