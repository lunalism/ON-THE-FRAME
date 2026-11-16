import Foundation
import Darwin

/// Test-only clocks. No pixel loops, I/O, global sample store, or full-frame copies.
enum IBPerfClock {
    struct Stamp {
        let wall: UInt64
        let thread: mach_port_t
        let threadCPU: Double?
        let processCPU: Double?
    }
    static func now(process: Bool = false) -> Stamp {
        let wall = DispatchTime.now().uptimeNanoseconds,thread = pthread_mach_thread_np(pthread_self())
        var info = thread_basic_info(),count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size/4)
        let status = withUnsafeMutablePointer(to:&info) { p in
            p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { thread_info(thread,thread_flavor_t(THREAD_BASIC_INFO),$0,&count) }
        }
        let cpu: Double? = status == KERN_SUCCESS ? Double(info.user_time.seconds)+Double(info.system_time.seconds)
            + (Double(info.user_time.microseconds)+Double(info.system_time.microseconds))/1_000_000 : nil
        var usage = rusage()
        let processStatus = process ? getrusage(RUSAGE_SELF,&usage) : -1
        let pcpu: Double? = processStatus == 0 ? Double(usage.ru_utime.tv_sec)+Double(usage.ru_stime.tv_sec)
            + (Double(usage.ru_utime.tv_usec)+Double(usage.ru_stime.tv_usec))/1_000_000 : nil
        return Stamp(wall:wall,thread:thread,threadCPU:cpu,processCPU:pcpu)
    }
    static func span(_ a:Stamp,_ b:Stamp) -> [String:Any] {
        var row:[String:Any] = ["wallSeconds":b.wall>=a.wall ? Double(b.wall-a.wall)/1e9 : "invalid-clock" as Any]
        func delta(_ x:Double?,_ y:Double?) -> Any {
            guard let x,let y,x.isFinite,y.isFinite,y>=x else { return "unavailable" }
            return y-x
        }
        row["threadCPUSeconds"] = a.thread==b.thread ? delta(a.threadCPU,b.threadCPU):"thread-migrated"
        row["processCPUSeconds"] = delta(a.processCPU,b.processCPU)
        return row
    }
}

final class IBPerfProbe {
    static let enabled = ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_PROBE"] == "1"
    private let start:IBPerfClock.Stamp
    private var last:IBPerfClock.Stamp
    private(set) var rows:[[String:Any]] = []
    init() { let stamp=IBPerfClock.now();start=stamp;last=stamp;rows.reserveCapacity(6) }
    func mark(_ label:String) {
        let stamp=IBPerfClock.now();var row=IBPerfClock.span(last,stamp);row["stage"]=label
        if rows.count<6 { rows.append(row) };last=stamp
    }
    var total:[String:Any] { IBPerfClock.span(start,last) }
}
