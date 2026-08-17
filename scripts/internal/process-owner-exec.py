#!/usr/bin/env python3
"""Acquire/probe/signal helper for agmsg process ownership.

The acquire path takes an advisory flock and execs the real watcher/bridge in
the same PID.  The signal path revalidates one generation immediately before
os.kill so a successor can never inherit an earlier authorization decision.
"""

import argparse
import errno
import fcntl
import os
import signal as signal_module
import sys
import tempfile
import time
import uuid
from typing import Optional

CONTENDED = 75
UNAVAILABLE = 69
HARD_ERROR = 70


def owner_path(pidfile: str) -> str:
    return f"{pidfile[:-4]}.owner" if pidfile.endswith(".pid") else f"{pidfile}.owner"


def lease_path(pidfile: str, generation: str = "") -> str:
    base = pidfile[:-4] if pidfile.endswith(".pid") else pidfile
    return f"{base}.lease.{generation}" if generation else f"{base}.lease.claim"


def read_pid(path: str) -> str:
    try:
        value = open(path, encoding="utf-8").readline().strip()
    except OSError:
        return ""
    return value if value.isdigit() and int(value) > 0 else ""


def read_owner(path: str):
    values = {}
    try:
        with open(path, encoding="utf-8") as stream:
            raw = stream.read()
    except OSError:
        return {}, b""
    for line in raw.splitlines():
        if "=" not in line:
            return {}, raw.encode()
        key, value = line.split("=", 1)
        if key in values:
            return {}, raw.encode()
        values[key] = value
    return values, raw.encode()


def atomic_write(path: str, data: str) -> None:
    directory = os.path.dirname(path) or "."
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def owner_text(pid: int, kind: str, scope: str, generation: str, lease: str, interpreter: str) -> str:
    return (
        "version=1\n"
        f"pid={pid}\n"
        f"kind={kind}\n"
        f"scope={scope}\n"
        f"generation={generation}\n"
        f"lease={lease}\n"
        f"interpreter={interpreter}\n"
    )


def pid_alive(pid: str) -> bool:
    if not pid.isdigit() or int(pid) <= 0:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def validate_replacement(args) -> None:
    current = read_pid(args.pidfile)
    current_owner, _raw = read_owner(owner_path(args.pidfile))
    current_generation = current_owner.get("generation", "")
    if current and current != args.replace_pid:
        raise SystemExit(CONTENDED)
    if current:
        if current_generation != args.replace_generation:
            raise SystemExit(CONTENDED)
    elif args.replace_pid:
        if not args.allow_missing_replace or current_generation:
            raise SystemExit(CONTENDED)
    elif current_generation != args.replace_generation:
        raise SystemExit(CONTENDED)


def remove_if_current(pidfile: str, pid: int, generation: str, companions) -> None:
    # The caller holds the claim lease, so this comparison and cleanup cannot
    # cross a cooperating successor publication.
    path = owner_path(pidfile)
    owner, _raw = read_owner(path)
    if owner.get("pid") != str(pid) or owner.get("generation") != generation:
        return
    if read_pid(pidfile) == str(pid):
        try:
            os.unlink(pidfile)
        except OSError:
            pass
    try:
        os.unlink(path)
    except OSError:
        pass
    if generation:
        try:
            os.unlink(lease_path(pidfile, generation))
        except OSError:
            pass
    for companion, _value in companions:
        try:
            os.unlink(companion)
        except OSError:
            pass


def publish_owner(args, generation: str, lease_mode: str, interpreter: str, fd: Optional[int]) -> None:
    pid = os.getpid()
    atomic_write(
        owner_path(args.pidfile),
        owner_text(pid, args.kind, args.scope, generation, lease_mode, interpreter),
    )
    atomic_write(args.pidfile, f"{pid}\n")
    for companion, value in args.companion:
        atomic_write(companion, value)
    os.environ["AGMSG_PROCESS_BOOTSTRAP_MODE"] = lease_mode
    os.environ["AGMSG_PROCESS_OWNER_GENERATION"] = generation
    if fd is not None:
        os.environ["AGMSG_PROCESS_OWNER_FD"] = str(fd)
    else:
        os.environ.pop("AGMSG_PROCESS_OWNER_FD", None)


def close_fd(fd: Optional[int]) -> None:
    if fd is None:
        return
    try:
        os.close(fd)
    except OSError:
        pass


def acquire_claim(args):
    try:
        fd = os.open(lease_path(args.pidfile), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as error:
        return None, HARD_ERROR, error
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        close_fd(fd)
        if error.errno in (errno.EACCES, errno.EAGAIN):
            return None, CONTENDED, error
        return None, HARD_ERROR, error

    # FD 19 belongs exclusively to the lifetime lease.  If open() selected it
    # for the claim, move the same locked file description out of the way.
    try:
        if fd == args.fd:
            duplicate = os.dup(fd)
            close_fd(fd)
            fd = duplicate
        else:
            close_fd(args.fd)
        os.set_inheritable(fd, False)
    except OSError as error:
        close_fd(fd)
        return None, HARD_ERROR, error
    return fd, 0, None


def acquire_generation_lease(args, generation: str):
    opened = None
    try:
        opened = os.open(lease_path(args.pidfile, generation), os.O_RDWR | os.O_CREAT, 0o600)
        if opened != args.fd:
            os.dup2(opened, args.fd, inheritable=True)
            close_fd(opened)
            opened = args.fd
        os.set_inheritable(args.fd, True)
        fcntl.flock(args.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return args.fd, None
    except OSError as error:
        close_fd(opened)
        if opened != args.fd:
            close_fd(args.fd)
        try:
            os.unlink(lease_path(args.pidfile, generation))
        except OSError:
            pass
        return None, error


def command_probe_interpreter(_args) -> int:
    with tempfile.TemporaryFile() as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    return 0


def command_acquire(args) -> int:
    protected = {args.pidfile, owner_path(args.pidfile), lease_path(args.pidfile)}
    if any(not os.path.isabs(path) or path in protected for path, _value in args.companion):
        return HARD_ERROR
    generation = uuid.uuid4().hex
    claim_fd, claim_status, claim_error = acquire_claim(args)
    if claim_fd is None:
        if claim_status == HARD_ERROR:
            print(
                f"agmsg identity: claim unavailable; refusing unleased publication: "
                f"{claim_error.__class__.__name__}",
                file=sys.stderr,
            )
        return claim_status

    owner_fd = None
    try:
        validate_replacement(args)
        owner_fd, lease_error = acquire_generation_lease(args, generation)
        lease_mode = "leased"
        if owner_fd is None:
            lease_mode = "degraded"
            print(
                f"agmsg identity: lease unavailable; falling back to PID-only dedup and no-signal: "
                f"{lease_error.__class__.__name__}",
                file=sys.stderr,
            )
        try:
            # Publication identifies the slot owner, but target signal readiness
            # follows only after exec and target initialization.
            publish_owner(args, generation, lease_mode, args.interpreter, owner_fd)
        except OSError as error:
            remove_if_current(args.pidfile, os.getpid(), generation, args.companion)
            print(f"agmsg identity: owner publication failed: {error.__class__.__name__}", file=sys.stderr)
            return HARD_ERROR
        try:
            os.execv(args.command[0], args.command)
        except OSError as error:
            remove_if_current(args.pidfile, os.getpid(), generation, args.companion)
            print(f"agmsg identity: target exec failed: {error.__class__.__name__}", file=sys.stderr)
            return HARD_ERROR
    finally:
        close_fd(owner_fd)
        close_fd(claim_fd)


def signal_number(name: str) -> int:
    value = name.upper()
    if value.startswith("SIG"):
        value = value[3:]
    if value not in {"TERM", "INT", "HUP", "KILL", "USR2"}:
        raise ValueError("unsupported signal")
    return int(getattr(signal_module, f"SIG{value}"))


def probe_open_lease(fd: int) -> int:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno in (errno.EACCES, errno.EAGAIN):
            return CONTENDED
        return UNAVAILABLE
    fcntl.flock(fd, fcntl.LOCK_UN)
    return 0


def wait_for_lease_release(fd: int, timeout: int) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        state = probe_open_lease(fd)
        if state == 0:
            return True
        if state != CONTENDED:
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.1, remaining))


def command_signal(args) -> int:
    path = owner_path(args.pidfile)
    first, first_raw = read_owner(path)
    first_pid = read_pid(args.pidfile)
    if not first_raw or first_pid != args.pid:
        return 1

    try:
        fd = os.open(lease_path(args.pidfile, args.generation), os.O_RDWR)
        if probe_open_lease(fd) != CONTENDED:
            return 1
    except OSError:
        return 1

    barrier = os.environ.get("AGMSG_TEST_PROCESS_SIGNAL_BARRIER", "")
    if barrier:
        open(f"{barrier}.reached", "w", encoding="utf-8").close()
        for _ in range(1000):
            if os.path.exists(f"{barrier}.release"):
                break
            time.sleep(0.01)

    second, second_raw = read_owner(path)
    second_pid = read_pid(args.pidfile)
    required = {
        "version": "1",
        "pid": args.pid,
        "kind": args.kind,
        "scope": args.scope,
        "generation": args.generation,
        "lease": "leased",
    }
    if first_raw != second_raw or first_pid != second_pid:
        return 1
    if any(first.get(key) != value or second.get(key) != value for key, value in required.items()):
        return 1
    if not pid_alive(args.pid):
        return 1
    # Re-probe the same open inode after the second generation read.  If the
    # former owner released it during validation, its PID is no longer safe.
    if probe_open_lease(fd) != CONTENDED:
        return 1

    try:
        number = signal_number(args.signal)
    except ValueError:
        return 1
    record = os.environ.get("AGMSG_TEST_PROCESS_SIGNAL_RECORD", "")
    if record:
        with open(record, "a", encoding="utf-8") as stream:
            stream.write(f"{args.pid}\t{args.signal}\t{args.generation}\n")
    else:
        try:
            os.kill(int(args.pid), number)
        except OSError:
            return 1
    if args.wait_release_timeout and not wait_for_lease_release(fd, args.wait_release_timeout):
        return CONTENDED
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="action", required=True)
    sub.add_parser("probe-interpreter")

    acquire = sub.add_parser("acquire")
    acquire.add_argument("--fd", type=int, required=True)
    acquire.add_argument("--pidfile", required=True)
    acquire.add_argument("--kind", required=True)
    acquire.add_argument("--scope", required=True)
    acquire.add_argument("--replace-pid", default="")
    acquire.add_argument("--replace-generation", default="")
    acquire.add_argument("--allow-missing-replace", action="store_true")
    acquire.add_argument("--companion", nargs=2, action="append", default=[])
    acquire.add_argument("--interpreter", required=True)
    acquire.add_argument("command", nargs=argparse.REMAINDER)

    send_signal = sub.add_parser("signal")
    send_signal.add_argument("--pidfile", required=True)
    send_signal.add_argument("--kind", required=True)
    send_signal.add_argument("--scope", required=True)
    send_signal.add_argument("--pid", required=True)
    send_signal.add_argument("--generation", required=True)
    send_signal.add_argument("--signal", required=True)
    send_signal.add_argument("--wait-release-timeout", type=int, default=0)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.action == "probe-interpreter":
        return command_probe_interpreter(args)
    if args.action == "signal":
        return command_signal(args)
    if not args.command:
        return HARD_ERROR
    if args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command or not os.path.isabs(args.command[0]):
        return HARD_ERROR
    return command_acquire(args)


if __name__ == "__main__":
    raise SystemExit(main())
