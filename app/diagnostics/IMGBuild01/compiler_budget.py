#!/usr/bin/env python3
"""macOS task-owned compiler runner: physical footprint, not just parent/RSS.
No dependencies or global settings. Output directories must be fresh.
"""
import ctypes,json,os,pathlib,signal,subprocess,time

_FIELDS='user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time'.split()
class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(f,ctypes.c_uint64) for f in _FIELDS]
_lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
_lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
_lib.proc_pid_rusage.restype=ctypes.c_int

def usage(pid):
    value=Usage()
    if _lib.proc_pid_rusage(pid,4,ctypes.byref(value)) != 0:return None
    return value

def processes():
    data=subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,comm='],text=True)
    result={}
    for row in data.splitlines():
        parts=row.strip().split(None,3)
        if len(parts)==4:result[int(parts[0])]=(int(parts[1]),int(parts[2]),parts[3])
    return result

def run(command,out,*,cwd=None,env=None,marker=None,seconds=120,per_process=3*1024**3,aggregate=4*1024**3):
    out=pathlib.Path(out);out.mkdir(parents=True,exist_ok=False)
    before=processes();start=time.monotonic();tracked={};samples=[];reason=None;stopped=False
    (out/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    (out/'limits.json').write_text(json.dumps({'seconds':seconds,'per_process_phys_bytes':per_process,'aggregate_phys_bytes':aggregate,'poll_seconds':0.1,'rusage_flavor':4,'ABI_bytes':ctypes.sizeof(Usage)},indent=2)+'\n')
    with (out/'output.log').open('w') as log:
        process=subprocess.Popen(command,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        def stop_owned():
            # Signal only this new process group, then verified new compiler children
            # if Xcode's build service placed them in another group. Never signal a
            # preexisting service or another application.
            try:os.killpg(process.pid,signal.SIGINT)
            except ProcessLookupError:pass
            for pid,row in tracked.items():
                current=usage(pid)
                if current and current.proc_start_abstime==row['start'] and pid not in before:
                    try:os.kill(pid,signal.SIGINT)
                    except ProcessLookupError:pass
        try:
            while process.poll() is None:
                table=processes();owned={process.pid}
                changed=True
                while changed:
                    old=len(owned);owned.update(pid for pid,(parent,group,exe) in table.items() if parent in owned or group==process.pid);changed=len(owned)!=old
                # Xcode may use an already running build service. Include only NEW
                # compiler processes whose own command identifies this diagnostic root.
                for pid,(_,_,exe) in table.items():
                    if marker and pid not in before and pid not in owned and pathlib.Path(exe).name in ('swift-frontend','swiftc','clang','ld'):
                        try:cmd=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
                        except subprocess.CalledProcessError:continue
                        if marker in cmd:owned.add(pid)
                owned.update(pid for pid,row in tracked.items() if pid in table)
                total=0;observed=[]
                for pid in owned:
                    u=usage(pid)
                    if u is None:continue
                    if pid in before and pid!=process.pid:continue
                    if pid not in tracked:
                        try:cmd=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
                        except subprocess.CalledProcessError:continue
                        tracked[pid]={'start':u.proc_start_abstime,'command':cmd,'peak_phys':0,'peak_rss':0,'kernel_peak_phys':0}
                    row=tracked[pid]
                    if row['start']!=u.proc_start_abstime:continue
                    row['peak_phys']=max(row['peak_phys'],u.phys_footprint);row['peak_rss']=max(row['peak_rss'],u.resident_size);row['kernel_peak_phys']=max(row['kernel_peak_phys'],u.lifetime_max_phys_footprint)
                    total+=u.phys_footprint;observed.append({'pid':pid,'phys':u.phys_footprint,'rss':u.resident_size})
                    if u.phys_footprint>=per_process:reason='per-process physical-footprint limit'
                if total>=aggregate:reason='aggregate physical-footprint limit'
                if time.monotonic()-start>=seconds:reason='execution time limit'
                samples.append({'seconds':time.monotonic()-start,'aggregate_phys':total,'processes':observed})
                if len(samples)%10==0:
                    (out/'processes.json').write_text(json.dumps(tracked,indent=2)+'\n')
                if reason:
                    stopped=True;stop_owned()
                    try:process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        # Escalation remains restricted to the exact newly launched job.
                        try:os.killpg(process.pid,signal.SIGKILL)
                        except ProcessLookupError:pass
                        for pid,row in tracked.items():
                            u=usage(pid)
                            if u and pid not in before and u.proc_start_abstime==row['start']:
                                try:os.kill(pid,signal.SIGKILL)
                                except ProcessLookupError:pass
                        process.wait()
                    break
                time.sleep(0.1)
        finally:
            if process.poll() is None:stop_owned();process.wait(timeout=15)
    (out/'samples.json').write_text(json.dumps(samples,indent=2)+'\n');(out/'processes.json').write_text(json.dumps(tracked,indent=2)+'\n')
    result={'exit':process.returncode,'safety_stop':stopped,'reason':reason,'seconds':time.monotonic()-start,'peak_aggregate_phys':max((x['aggregate_phys'] for x in samples),default=0),'peak_process_phys':max((x['peak_phys'] for x in tracked.values()),default=0),'peak_kernel_lifetime_phys':max((x['kernel_peak_phys'] for x in tracked.values()),default=0)}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');return result
