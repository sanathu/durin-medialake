//
//  FileUploadOperation.swift
//  MediaUploader
//
//  Copyright © 2020 GlobalLogic. All rights reserved.
//

import Cocoa


final class FileUploadOperation: AsyncOperation , NSCopying {

    enum UploadType {
        case kMetadataJsonUpload
        case kDataUpload
        case kPendingRetry
    }
    
    private let showId: String
    private let cdsUserId: String
    private let sasToken: String
    
    var tableRowRef : UploadTableRow?
    var completionStatus : Int

    private let args: [String]
    var step: FileUploadOperation.UploadType
    
    // upload being performed in two steps:
    // firstly we upload metadata.json(parent task), in this case dependens contains data tasks
    // second is we upload actually data -> dependens is empty
    weak var parent : FileUploadOperation?
    var dependens : [FileUploadOperation]!
    var retry : Bool = false // indicates is this retry attempt or not
    
    init(showId: String, cdsUserId: String, sasToken: String, step: FileUploadOperation.UploadType, tableRowRef: UploadTableRow?, dependens : [FileUploadOperation], args: [String]) {
        self.showId = showId
        self.cdsUserId = cdsUserId
        self.sasToken = sasToken
        self.tableRowRef = tableRowRef
        self.completionStatus = 0
        
        self.parent = nil
        self.dependens = dependens
        
        self.step = step
        self.args = args
        
        super.init()
        
        self.tableRowRef?.taskRef = self
        
        for dep in dependens {
            dep.parent = self
        }
    }

    deinit {
        print (" ------- deinit FileUploadOperation, self: ", self)
    }
    
    func copy(with zone: NSZone? = nil) -> Any {
        let copy = FileUploadOperation(showId: showId,
                                      cdsUserId: cdsUserId,
                                      sasToken: sasToken,
                                      step: step,
                                      tableRowRef: tableRowRef,
                                      dependens: dependens,
                                      args: args)
            return copy
        }
    
    override func main() {
        let (_, error, status) = runAzCopyCommand(cmd: LoginViewController.azcopyPath.path, args: self.args)
        
        if status == 0 {
            if self.step == UploadType.kMetadataJsonUpload {
                print ("------------  Completed successfully: \(sasToken) ")
                print ("------------  Cleanup of ", self.args[1])
                removeConfig(path: self.args[1])
                

            } else if self.step == UploadType.kDataUpload {
                DispatchQueue.main.async {
                    self.tableRowRef!.uploadProgress = 100.0
                    self.tableRowRef!.completionStatusString = "Completed"
                    print ("------------  Upload of data completed successfully!")
                    NotificationCenter.default.post(name: Notification.Name(WindowViewController.NotificationNames.UpdateShowUploadProgress),
                                                    object: nil,
                                                    userInfo: ["showName" : self.tableRowRef!.showName,
                                                               "progress" : self.tableRowRef!.uploadProgress])
                    // update show content
//                    NotificationCenter.default.post(
//                        name: Notification.Name(WindowViewController.NotificationNames.ShowProgressViewController),
//                        object: nil,
//                        userInfo: ["progressLabel" : kFetchingShowContentStr])
//
//                    NotificationCenter.default.post(
//                        name: Notification.Name(WindowViewController.NotificationNames.IconSelectionChanged),
//                        object: nil,
//                        userInfo: ["showName" : self.showName, "showId": self.showId, "cdsUserId" : self.cdsUserId])
                    
                }
            }
        } else {
            DispatchQueue.main.async {
                if self.step == UploadType.kMetadataJsonUpload {
                    for dep in self.dependens {
                        dep.retry = false
                        print(dep.tableRowRef!.completionStatusString)
                        dep.tableRowRef!.uploadProgress = 100.0
                        print ("------------  Upload failed, error: ", error)
                        
                        uploadShowErrorAndNotify(error: OutlineViewController.NameConstants.kUploadShowFailedStr, params: dep.tableRowRef!.uploadParams, operation: self)
                    }
                } else if self.step == UploadType.kDataUpload {
                    print(self.tableRowRef!.completionStatusString)
                    self.tableRowRef!.uploadProgress = 100.0
                    print ("------------  Upload failed, error: ", error)
                    uploadShowErrorAndNotify(error: OutlineViewController.NameConstants.kUploadShowFailedStr, params: self.tableRowRef!.uploadParams, operation: self)
                }
 
                NotificationCenter.default.post(name: Notification.Name(WindowViewController.NotificationNames.UpdateShowUploadProgress),
                                                object: nil)
            }
        }
        self.finish()
    }

    override func cancel() {
        super.cancel()
    }
    
    
    // WARNING: Sandboxed application fairly limited in what it can actually sub-launch
    //          So external programm need to be placed to /Applications folder
    internal func runAzCopyCommand(cmd : String, args : [String]) -> (output: [String], error: String, exitCode: Int32) {

        let output : [String] = []
        var error : String = ""

        let task = Process()
        task.launchPath = cmd
        task.arguments = args
        
        let outpipe = Pipe()
        task.standardOutput = outpipe
        //let errpipe = Pipe()
        //task.standardError = errpipe

        var terminationObserver : NSObjectProtocol!
        terminationObserver = NotificationCenter.default.addObserver(forName: Process.didTerminateNotification,
                                                      object: task, queue: nil) { notification -> Void in
            NotificationCenter.default.removeObserver(terminationObserver!)
        }
        
        
        outpipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
        var outpipeObserver : NSObjectProtocol!
        outpipeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable, object: outpipe.fileHandleForReading , queue: nil) {
            notification in
            let output = outpipe.fileHandleForReading.availableData
            if (output.count > 0) {
                let outputString = String(data: output, encoding: String.Encoding.utf8) ?? ""
                
                print(outputString)
                let (status, error_output) = self.parseResult(inputString: outputString)
                if status != 0 {
                    self.completionStatus = status
                    error = error_output
                    return
                }
            }
            outpipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
            
        }
        
        outpipe.fileHandleForReading.readabilityHandler = { (fileHandle) -> Void in
            let availableData = fileHandle.availableData
            let newOutput = String.init(data: availableData, encoding: .utf8)
            
            print("\(newOutput!)")
            
            
            var result: [[String]] = []
            
            let pattern = #"(\d+.\d+) %"#
            let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            let testString = newOutput
            
            let stringRange = NSRange(location: 0, length: (testString?.utf8.count)!)
            let matches = regex.matches(in: testString!, range: stringRange)
            
            for match in matches {
                var groups: [String] = []
                for rangeIndex in 1 ..< match.numberOfRanges {
                    groups.append((testString! as NSString).substring(with: match.range(at: rangeIndex)))
                }
                if !groups.isEmpty {
                    result.append(groups)
                }
            }
            
            let (status, error_output) = self.parseResult(inputString: newOutput!)
            if status != 0 {
                self.completionStatus = status
                error = error_output
                return
            }
            
            // advance progress only for actually upload data stage
            if !result.isEmpty && self.step == FileUploadOperation.UploadType.kDataUpload {
                self.tableRowRef!.uploadProgress = ceil(Double(result[0][0])! + 0.5)
                print("------------ progress : ", self.tableRowRef!.showName, " ", self.tableRowRef!.uploadProgress, " >> ", result[0])
            }
            
            DispatchQueue.main.async {
                if !result.isEmpty {
                    NotificationCenter.default.post(name: Notification.Name(WindowViewController.NotificationNames.UpdateShowUploadProgress),
                                                    object: nil)
                }
            }
        }
        
        
    //    var errpipeObserver : NSObjectProtocol!
    //    errpipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
    //
    //    errpipeObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable, object: errpipe.fileHandleForReading , queue: nil) {
    //        notification in
    //            let output = outpipe.fileHandleForReading.availableData
    //            if (output.count > 0) {
    //                let errorString = String(data: output, encoding: String.Encoding.utf8) ?? ""
    //
    //                DispatchQueue.main.async(execute: {
    //                    print(errorString)
    //
    //                })
    //                //output = nil
    //            }
    //        errpipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
    //    }
    //
        
        task.launch()
        
        task.waitUntilExit()
        var status = task.terminationStatus
        
        outpipe.fileHandleForReading.readabilityHandler = nil
        NotificationCenter.default.removeObserver(outpipeObserver!)
        //NotificationCenter.default.removeObserver(errpipeObserver!)
        
        // AzCopy completed with return code 0 but operation failed
        if status == 0 && self.completionStatus != 0 {
            status = Int32(self.completionStatus)
        }
        
        return (output, error, status)
    }
    
    func parseResult(inputString: String) -> (Int,String) {
        var error: String = ""
        var resultString = getCompletionStatusString(inputString: inputString)
        if !resultString.isEmpty {
            
            if resultString != "Completed_NOT" {
                resultString = "Failed"
                if self.step == UploadType.kMetadataJsonUpload {
                    for dep in self.dependens {
                        dep.tableRowRef!.completionStatusString = resultString
                    }
                    error = "Failed AzCopy metadata.json Upload!"
                } else {
                    self.tableRowRef!.completionStatusString = resultString
                    error = "Failed AzCopy data Upload!"
                }
                
                return (-1, error)
            }
        }
        return (0, error)
    }
}



func getCompletionStatusString(inputString : String) -> String {
    let pattern = #"Final Job Status:(\s+\w+)\n"#
    let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    let stringRange = NSRange(location: 0, length: inputString.utf8.count)
    let matches = regex.matches(in: inputString, range: stringRange)
    var result: [[String]] = []
    for match in matches {
        var groups: [String] = []
        for rangeIndex in 1 ..< match.numberOfRanges {
            groups.append((inputString as NSString).substring(with: match.range(at: rangeIndex)))
        }
        if !groups.isEmpty {
            result.append(groups)
        }
    }
    if (result.count != 0) {
        print ("----------------- getCompletionStatusString: ", result[0][0])
        return result[0][0].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}
