"""Dedicated Debug child runner. APP FIXTURE --output FRESH_DIR; or APP --regression --output FRESH_DIR.
The owner selects the original fixture directory in the continuous child. Evidence is host-written.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid
import argparse
import queue
import threading


class ProcBSDInfo(ctypes.Structure):
    # SDK sys/proc_info.h: proc_bsdinfo (PROC_PIDTBSDINFO).
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
        "svuid", "svgid", "reserved")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
        ("jobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("startSeconds", ctypes.c_uint64), ("startMicroseconds", ctypes.c_uint64)]


def identity(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    info = ProcBSDInfo()
    require(ctypes.sizeof(info) == 136, "unsupported proc_bsdinfo ABI")
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    path = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(pid, path, len(path)) <= 0:
        return None
    return {"pid": info.pid, "ppid": info.ppid, "uid": info.uid,
            "startSeconds": info.startSeconds, "startMicroseconds": info.startMicroseconds,
            "executable": os.fsdecode(path.value)}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode(data):
    def fields(pairs):
        result = dict(pairs)
        require(len(result) == len(pairs), "duplicate JSON field")
        return result

    def invalid_number(value):
        raise ValueError("invalid JSON number: " + value)

    return json.loads(data, object_pairs_hook=fields, parse_constant=invalid_number)


def receive(channel, run, check_deadline=None, record=None):
    deadline = time.monotonic() + 60

    def read(size):
        while True:
            remaining = check_deadline() if check_deadline else deadline - time.monotonic()
            require(remaining > 0, "delivery deadline")
            channel.settimeout(min(remaining, .2))
            try:
                return channel.recv(size)
            except socket.timeout:
                continue

    def payload(size):
        data = bytearray()
        while len(data) < size:
            chunk = read(min(65536, size - len(data)))
            require(chunk, "truncated payload")
            data.extend(chunk)
        return data

    # Validate the small header before reading or allocating for either payload.
    prefix = bytearray()
    while len(prefix) < 4096:
        byte = read(1)
        require(byte, "truncated header")
        if byte == b"\n":
            break
        prefix.extend(byte)
    require(len(prefix) < 4096, "oversized header")
    if record:
        record("received-header.json", prefix)
    header = decode(prefix)
    require(header["protocol"] == "OTFContinuous" and type(header["version"]) is int
            and header["version"] == 1 and header["runID"] == run, "foreign record")
    r, t = header["reportBytes"], header["traceBytes"]
    require(type(r) is int and type(t) is int and 0 < r <= 4 << 20 and 0 <= t <= 2 << 20,
            "invalid payload lengths")
    require(type(header["rows"]) is int and 0 <= header["rows"] <= 3000
            and type(header["mayStopChild"]) is bool, "invalid row count or lifecycle flag")
    report_data = payload(r)
    if record:
        record("received-report.json", report_data)
    trace_data = payload(t)
    if record and trace_data:
        record("received-trace.json", trace_data)
    require(not read(1), "extra bytes after record")
    require(hashlib.sha256(report_data).hexdigest() == header["reportSHA256"]
            and hashlib.sha256(trace_data).hexdigest() == header["traceSHA256"], "digest mismatch")
    report = decode(report_data)
    rows = report["frames"]
    require(report["runID"] == run and isinstance(rows, list) and len(rows) == header["rows"]
            and all(isinstance(row, dict) for row in rows), "report identity or row count")
    if trace_data:
        trace = decode(trace_data)
        require(trace["runID"] == run and isinstance(trace["events"], list)
                and type(trace["eventCount"]) is int and len(trace["events"]) == trace["eventCount"] <= 8192
                and all(isinstance(event, list) and len(event) == 10 and all(type(v) is int for v in event)
                        for event in trace["events"]), "trace identity or event count")
    status = header["status"]
    require(status in ("PASS", "FAIL"), "invalid status")
    if status == "PASS":
        require(rows and trace_data and trace["truncated"] is False and trace["tracerValidation"] is True
                and report["status"] == "CONTINUOUS CAPTURE COMPLETE" and report["endFrame"] == 360
                and report["fixtureUnchanged"] is True and report["ownedResourcesReleased"] is True
                and "error" not in report and "traceError" not in report
                and header["mayStopChild"] is True, "inconsistent success")
    if record:
        record("header.json", prefix)
        record("report.json", report_data)
        if trace_data:
            record("trace.json", trace_data)
    return status, header["mayStopChild"] is True, len(rows), report.get("error")


def main(app, fixture=None, *, regression=False, output=None):
    run = str(uuid.uuid4()).upper()
    outcome = {"runID": run, "status": "INCOMPLETE", "recordComplete": False,
               "terminationRequested": False, "launcherPID": os.getpid()}
    destination = Path(output).absolute() if output else None
    output_fd = None
    # Pin a fresh host-owned directory; later path replacement cannot redirect writes.
    if destination:
        roots = [Path("/Volumes/LunaData/dev/ON-THE-FRAME/app"),
                 Path("/Volumes/LunaData/dev/ON-THE-FRAME/experiments"),
                 Path("/Users/chris/Library/Developer/ON-THE-FRAME")]
        require(destination.resolve(strict=True) == destination and
                any(root in destination.parents for root in roots), "output outside approved scope or symbolic link")
        output_fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        require(os.fstat(output_fd).st_uid == os.getuid() and not os.listdir(output_fd),
                "fresh empty owned output required")

    def record(name, data):
        if output_fd is not None:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=output_fd)
            with os.fdopen(fd, "wb") as file:
                file.write(data)

    executable = (Path(app).resolve(strict=True) / "Contents/MacOS/OnTheFrame").resolve(strict=True)
    require(executable.name == "OnTheFrame" and executable.is_file(), "unexpected executable")
    environment = dict(os.environ, OTF_CONTINUOUS_RUN=run)
    flag = "-OTFStartupFrameContract" if regression else "-OTFContinuousParityTest"
    if regression:
        environment["OTF_DIRECT_REGRESSION"] = "1"
    else:
        require(fixture is not None, "fixture path required")
        environment["OTF_CONTINUOUS_FIXTURE"] = str(Path(fixture).resolve(strict=True))
    reader, writer = socket.socketpair()
    environment["OTF_RESULT_FD"] = str(writer.fileno())
    events = queue.Queue(maxsize=16)
    phase = "startup"
    deadline = time.monotonic() + 15
    completion = None
    phase_log = []
    limits = {"selection": 180, "preflight": 60, "playback": 25, "delivery": 15}
    allowed = {"startup": {"selection", "regressionComplete"},
               "selection": {"preflight", "delivery"},
               "preflight": {"playback", "delivery"}, "playback": {"delivery"},
               "delivery": {"deliveryFailure"}}

    def collect_stderr(pipe):
        # Bounded lines and queue. Ordinary app logging cannot consume unbounded memory.
        with pipe:
            while True:
                line = pipe.readline(16385)
                if not line:
                    return
                if len(line) > 16384 or not line.endswith(b"\n"):
                    try: events.put_nowait({"invalid": "oversized stderr line"})
                    except queue.Full: pass
                    return
                if line.startswith(b"OTF_DEBUG "):
                    try:
                        value = decode(line[len(b"OTF_DEBUG "):])
                        events.put_nowait(value)
                    except (ValueError, TypeError, queue.Full):
                        try: events.put_nowait({"invalid": "invalid control message"})
                        except queue.Full: pass
                        return

    def check_deadline():
        nonlocal phase, deadline, completion
        while True:
            try: value = events.get_nowait()
            except queue.Empty: break
            require(isinstance(value, dict) and value.get("runID") == run, "foreign control message")
            next_phase = value.get("phase")
            require(next_phase in allowed.get(phase, set()), "invalid phase transition")
            require((next_phase == "regressionComplete") == regression
                    if phase == "startup" else not regression, "wrong test mode")
            phase = next_phase
            phase_log.append({"phase": phase, "observedMonotonic": time.monotonic()})
            if phase == "regressionComplete":
                completion = value
                deadline = time.monotonic() + 5
            else:
                require(phase != "deliveryFailure", value.get("error", "socket delivery failed"))
                deadline = time.monotonic() + limits[phase]
        remaining = deadline - time.monotonic()
        require(remaining > 0, phase + " timeout")
        return remaining

    child = None
    who = None
    try:
        with reader, writer:
            child = subprocess.Popen([str(executable), flag], env=environment,
                                     pass_fds=(writer.fileno(),), stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE)
            writer.close()
            threading.Thread(target=collect_stderr, args=(child.stderr,), daemon=True).start()
            # Bounded startup identity acquisition; never signal an unverified child.
            while who is None and child.poll() is None and time.monotonic() < deadline:
                candidate = identity(child.pid)
                if candidate and candidate["executable"] == str(executable):
                    who = candidate
                else:
                    time.sleep(.02)
            outcome.update(pid=child.pid, identity=who)
            require(who is not None and who["ppid"] == os.getpid() and who["uid"] == os.getuid(),
                    "direct child identity unavailable or ownership mismatch")
            if regression:
                while completion is None:
                    check_deadline()
                    require(child.poll() is None or completion is not None, "child exited before completion")
                    time.sleep(.02)
                checks = completion.get("checks")
                require(isinstance(checks, list) and len(checks) == 17 and
                        all(isinstance(c, dict) and type(c.get("pass")) is bool for c in checks),
                        "invalid regression completion")
                may_stop = completion.get("mayStopChild") is True
                status = "PASS" if all(c["pass"] for c in checks) else "FAIL"
                record("startup-contract.json", json.dumps(completion).encode())
                outcome["checks"] = checks
            else:
                status, may_stop, rows, error = receive(reader, run, check_deadline, record)
                while phase != "delivery":
                    check_deadline()
                    time.sleep(.02)
                outcome.update(rows=rows, diagnosticError=error)
            outcome.update(status=status, recordComplete=True, terminationEligible=may_stop)
            if may_stop and child.poll() is None:
                require(identity(child.pid) == who, "child identity changed before signal")
                child.terminate()
                outcome.update(terminationRequested=True, signal="SIGTERM", signalInitiator=os.getpid())
    except (OSError, ValueError, KeyError, TypeError, RecursionError, subprocess.TimeoutExpired) as exc:
        outcome["error"] = str(exc)
    finally:
        if child:
            try:
                outcome["childExit"] = child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                current = identity(child.pid)
                outcome.update(childExit=None, residualIdentity=current,
                               residualMatchesSpawned=current is not None and current == who,
                               residualReason="bounded wait expired; no further signal authorized")
            if outcome.get("terminationRequested") and outcome.get("childExit") not in (0, -15):
                outcome["lifecycleError"] = "unexpected exit after SIGTERM"
            outcome["childAlive"] = child.poll() is None
        outcome["phases"] = phase_log
    record("outcome.json", json.dumps(outcome).encode())
    print(json.dumps(outcome), flush=True)
    if output_fd is not None:
        os.close(output_fd)
    return 0 if (outcome["status"] == "PASS" and outcome.get("childExit") in (0, -15)
                 and not outcome.get("error") and not outcome.get("lifecycleError")) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("fixture", nargs="?")
    parser.add_argument("--regression", action="store_true")
    parser.add_argument("--output", required=True, help="fresh empty task-owned evidence directory")
    args = parser.parse_args()
    sys.exit(main(args.app, args.fixture, regression=args.regression, output=args.output))
