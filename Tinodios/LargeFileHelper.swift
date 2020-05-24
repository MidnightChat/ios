//
//  LargeFileHelper.swift
//  Midnightios
//
//  Copyright © 2019 Midnight. All rights reserved.
//

import Foundation
import UIKit
import MidnightSDK

class Upload {
    var url: URL
    var topicId: String
    var msgId: Int64 = 0
    var isUploading = false
    var progress: Float = 0
    var responseData: Data = Data()
    var progressCb: ((Float) -> Void)?
    var finalCb: ((ServerMessage?, Error?) -> Void)?

    var task: URLSessionUploadTask?

    init(url: URL) {
        self.url = url
        self.topicId = ""
    }
    deinit {
        if let cb = finalCb {
            cb(nil, MidnightError.invalidState("Topic \(topicId), msg id \(msgId): Could not finish upload. Cancelling."))
        }
    }
}

class LargeFileHelper: NSObject {
    static let kBoundary = "*****\(Int64(Date().timeIntervalSince1970 as Double * 1000))*****"
    static let kTwoHyphens = "--"
    static let kLineEnd = "\r\n"

    var urlSession: URLSession!
    var activeUploads: [String : Upload] = [:]
    init(config: URLSessionConfiguration) {
        super.init()
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    convenience override init() {
        let config = URLSessionConfiguration.background(withIdentifier: Bundle.main.bundleIdentifier!)
        self.init(config: config)
    }
    private static func addCommonHeaders(to request: inout URLRequest, using midnight: Midnight) {
        request.addValue(midnight.apiKey, forHTTPHeaderField: "X-Midnight-APIKey")
        request.addValue("Token \(midnight.authToken!)", forHTTPHeaderField: "X-Midnight-Auth")
    }
    public static func createUploadKey(topicId: String, msgId: Int64) -> String {
        return "\(topicId)-\(msgId)"
    }
    // TODO: make background uploads work.
    func startUpload(filename: String, mimetype: String, d: Data, topicId: String, msgId: Int64,
                     progressCallback: @escaping (Float) -> Void,
                     completionCallback: @escaping (ServerMessage?, Error?) -> Void) {
        let midnight = Cache.getMidnight()
        guard var url = midnight.baseURL(useWebsocketProtocol: false) else { return }
        url.appendPathComponent("file/u/")
        let upload = Upload(url: url)
        var request = URLRequest(url: url)

        request.httpMethod = "POST"
        request.addValue("Keep-Alive", forHTTPHeaderField: "Connection")
        request.addValue(midnight.userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("multipart/form-data; boundary=\(LargeFileHelper.kBoundary)", forHTTPHeaderField: "Content-Type")

        LargeFileHelper.addCommonHeaders(to: &request, using: midnight)

        var newData = Data()
        let header = LargeFileHelper.kTwoHyphens + LargeFileHelper.kBoundary + LargeFileHelper.kLineEnd +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"" + LargeFileHelper.kLineEnd +
            "Content-Type: \(mimetype)" + LargeFileHelper.kLineEnd +
            "Content-Transfer-Encoding: binary" + LargeFileHelper.kLineEnd + LargeFileHelper.kLineEnd
        newData.append(contentsOf: header.utf8)
        newData.append(d)
        let footer = LargeFileHelper.kLineEnd + LargeFileHelper.kTwoHyphens + LargeFileHelper.kBoundary + LargeFileHelper.kTwoHyphens + LargeFileHelper.kLineEnd
        newData.append(contentsOf: footer.utf8)

        let tempDir = FileManager.default.temporaryDirectory

        let localFileName = UUID().uuidString
        let localURL = tempDir.appendingPathComponent("throwaway-\(localFileName)")
        try? newData.write(to: localURL)

        let uploadKey = LargeFileHelper.createUploadKey(topicId: topicId, msgId: msgId)
        upload.task = urlSession.uploadTask(with: request, fromFile: localURL)
        upload.task!.taskDescription = uploadKey
        upload.isUploading = true
        upload.topicId = topicId
        upload.msgId = msgId
        upload.progressCb = progressCallback
        upload.finalCb = completionCallback
        activeUploads[uploadKey] = upload
        upload.task!.resume()
    }

    func cancelUpload(topicId: String, msgId: Int64) -> Bool {
        let uploadKey = LargeFileHelper.createUploadKey(topicId: topicId, msgId: msgId)
        var upload = activeUploads[uploadKey]
        guard upload != nil else { return false }
        activeUploads.removeValue(forKey: uploadKey)
        upload!.task?.cancel()
        upload = nil
        return true
    }

    func startDownload(from url: URL) {
        let midnight = Cache.getMidnight()
        var request = URLRequest(url: url)
        LargeFileHelper.addCommonHeaders(to: &request, using: midnight)

        let task = urlSession.downloadTask(with: request)
        task.resume()
    }
}

extension LargeFileHelper: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                let completionHandler = appDelegate.backgroundSessionCompletionHandler {
                appDelegate.backgroundSessionCompletionHandler = nil
                completionHandler()
            }
        }
    }
}
extension LargeFileHelper: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive: Data) {
        if let taskId = dataTask.taskDescription, let upload = activeUploads[taskId] {
            upload.responseData.append(didReceive)
        }
    }
}
extension LargeFileHelper: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError: Error?) {
        guard let taskId = task.taskDescription, let upload = activeUploads[taskId] else {
            return
        }
        activeUploads.removeValue(forKey: taskId)
        var serverMsg: ServerMessage? = nil
        var uploadError: Error? = didCompleteWithError
        defer {
            upload.finalCb?(serverMsg, uploadError)
            upload.finalCb = nil
        }
        guard uploadError == nil else {
            return
        }
        Cache.log.debug("LargeFileHelper - finished task: id = %@, topicId = %@", taskId, upload.topicId)
        guard let response = task.response as? HTTPURLResponse else {
            uploadError = MidnightError.invalidState(String(format: NSLocalizedString("Upload failed (%@). No server response.", comment: "Error message"), upload.topicId))
            return
        }
        guard response.statusCode == 200 else {
            uploadError = MidnightError.invalidState(String(format: NSLocalizedString("Upload failed (%@): response code %d.", comment: "Error message"), upload.topicId, response.statusCode))
            return
        }
        guard !upload.responseData.isEmpty else {
            uploadError = MidnightError.invalidState(String(format: NSLocalizedString("Upload failed (%@): empty response body.", comment: "Error message"), upload.topicId))
            return
        }
        do {
            serverMsg = try Midnight.jsonDecoder.decode(ServerMessage.self, from: upload.responseData)
        } catch {
            uploadError = error
            return
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Thread.sleep(forTimeInterval: 0.1)
        if let t = task.taskDescription, let upload = activeUploads[t] {
            let progress: Float = totalBytesExpectedToSend > 0 ?
                Float(totalBytesSent) / Float(totalBytesExpectedToSend) : 0
            upload.progressCb?(progress)
        }
    }
}
// Downloads.
extension LargeFileHelper: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard downloadTask.error == nil else {
            Cache.log.error("LargeFileHelper - download failed: %@", downloadTask.error!.localizedDescription)
            return
        }

        guard let url = downloadTask.originalRequest?.url else { return }
        let fn = url.extractQueryParam(withName: "origfn") ?? url.lastPathComponent

        let documentsUrl: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsUrl.appendingPathComponent(fn)

        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: destinationURL)
        } catch {
            // Non-fatal: file probably doesn't exist
        }
        do {
            try fileManager.moveItem(at: location, to: destinationURL)
            UiUtils.presentFileSharingVC(for: destinationURL)
        } catch {
            Cache.log.error("LargeFileHelper - could not copy file to disk: %@", error.localizedDescription)
        }
    }
}
