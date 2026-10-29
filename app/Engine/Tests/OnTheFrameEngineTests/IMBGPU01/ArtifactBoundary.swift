import Foundation

enum GMArtifactBoundary {
    static func check(root:URL,parent:URL,extra:Int=0,newLimit:Int=536_870_912,combinedLimit:Int=21_474_836_480,combined:()throws->Int)throws->Int {
        let fm=FileManager.default,p=parent.standardizedFileURL,r=root.standardizedFileURL
        guard !root.pathComponents.contains(".."),r.deletingLastPathComponent().pathComponents==p.pathComponents,r != p,
              r.resolvingSymlinksInPath()==r,p.resolvingSymlinksInPath()==p,
              (try r.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true else{throw IBContract.error("artifact boundary invalid",code:300)}
        var failure:Error?,total=extra
        guard let e=fm.enumerator(at:r,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey,.totalFileAllocatedSizeKey],options:[],errorHandler:{_,err in failure=err;return false}) else{throw IBContract.error("artifact enumeration failed",code:300)}
        for case let u as URL in e {
            let v=try u.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey,.totalFileAllocatedSizeKey])
            guard v.isSymbolicLink==false,u.resolvingSymlinksInPath().path.hasPrefix(r.path+"/") else{throw IBContract.error("artifact symlink/escape",code:300)}
            if v.isRegularFile==true {guard let s=v.fileSize,let a=v.totalFileAllocatedSize else{throw IBContract.error("artifact size unavailable",code:300)};let (sum,overflow)=total.addingReportingOverflow(max(s,a));guard !overflow else{throw IBContract.error("artifact size overflow",code:300)};total=sum}
            else if v.isDirectory != true{throw IBContract.error("artifact unsupported entry",code:300)}
        }
        if let failure{throw failure}
        guard total<=newLimit,try combined()<=combinedLimit else{throw IBContract.error("artifact/combined budget exceeded",code:300)}
        return total
    }
    /// du does not follow symlinks: external trees cannot be traversed via a link.
    static func allocated(_ paths:[String])throws->Int {
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/usr/bin/du");task.arguments=["-sk"]+paths;task.standardOutput=pipe
        try task.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        guard task.terminationStatus==0,let text=String(data:data,encoding:.utf8) else{throw IBContract.error("combined accounting unavailable",code:300)}
        let rows=text.split(separator:"\n");guard rows.count==paths.count else{throw IBContract.error("combined accounting incomplete",code:300)}
        var sum=0
        for row in rows {guard let first=row.split(whereSeparator:{$0=="\t" || $0==" "}).first,let n=Int(first),n>=0,n<Int.max/1024 else{throw IBContract.error("combined accounting malformed",code:300)};let (next,o)=sum.addingReportingOverflow(n*1024);guard !o else{throw IBContract.error("combined overflow",code:300)};sum=next}
        return sum
    }
}
