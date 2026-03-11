wit_bindgen::generate!({
    path: "../../../runtime/wit/flix-bindings",
    world: "flix",
    generate_all,
});

use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};

struct Component;

export!(Component);

#[derive(Default)]
struct CtxRep {
    id: u64,
    state: RefCell<CtxState>,
}

#[derive(Default)]
struct CtxState {
    next_task_id: u64,
    tasks: BTreeMap<u64, TaskRep>,
    ready: VecDeque<u64>,
}

struct TaskRep {
    def_id: u64,
    args: Vec<ValueRep>,
    state: TaskState,
    tcp_roundtrip: Option<TcpRoundtripScratch>,
    proc_roundtrip: Option<ProcessRoundtripScratch>,
}

#[derive(Clone)]
enum ValueRep {
    I32(i32),
    Bool(bool),
    String(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TcpRoundtripStage {
    Bind,
    LocalPort,
    Connect,
    Accept,
    ClientWrite,
    ServerRead,
    CloseServerSocket,
    CloseClientSocket,
    CloseServer,
}

struct TcpRoundtripScratch {
    stage: TcpRoundtripStage,
    server_id: Option<u64>,
    port: Option<u16>,
    client_socket_id: Option<u64>,
    server_socket_id: Option<u64>,
    recv: Vec<u8>,
}

impl TcpRoundtripScratch {
    fn new() -> Self {
        Self {
            stage: TcpRoundtripStage::Bind,
            server_id: None,
            port: None,
            client_socket_id: None,
            server_socket_id: None,
            recv: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProcessRoundtripStage {
    Exec,
    Pid,
    IsAliveBefore,
    WaitTimeout,
    StdoutReady,
    StdinWrite,
    StdoutOk,
    StderrErr,
    WaitFor,
    ExitValue,
    IsAliveAfter,
    Release,
}

struct ProcessRoundtripScratch {
    stage: ProcessRoundtripStage,
    process_id: Option<u64>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

impl ProcessRoundtripScratch {
    fn new() -> Self {
        Self {
            stage: ProcessRoundtripStage::Exec,
            process_id: None,
            stdout: Vec::new(),
            stderr: Vec::new(),
        }
    }
}

#[derive(Clone, Copy)]
enum SuspensionReqRep {
    TimerSleep { ms: u64 },
    HttpRequest,
    FileExists,
    FileIsDirectory,
    FileIsRegularFile,
    FileIsReadable,
    FileIsSymbolicLink,
    FileIsWritable,
    FileIsExecutable,
    FileAccessTime,
    FileCreationTime,
    FileModificationTime,
    FileSize,
    FileRead,
    FileReadLines,
    FileReadBytes,
    FileList,
    FileWrite,
    FileWriteBytes,
    FileAppend,
    FileAppendBytes,
    FileTruncate,
    FileMkdir,
    FileMkdirs,
    FileMkTempDir,
    ProcessExec,
    ProcessExitValue,
    ProcessIsAlive,
    ProcessPid,
    ProcessStop,
    ProcessWaitFor,
    ProcessWaitForTimeout,
    ProcessStdinWrite,
    ProcessStdoutRead,
    ProcessStderrRead,
    ProcessRelease,
    TcpSocketConnect,
    TcpSocketRead,
    TcpSocketWrite,
    TcpSocketClose,
    TcpServerBind,
    TcpServerAccept,
    TcpServerLocalPort,
    TcpServerClose,
    Unknown,
}

struct SuspensionRep {
    task_id: u64,
    eff_id: u64,
    op_id: u64,
    req: SuspensionReqRep,
}

enum TaskState {
    Ready(TaskStep),
    Blocked,
    Completed { outcome: TaskOutcomeRep, consumed: bool },
    Poison,
}

enum TaskStep {
    Start,
    ResumeOk(ValueRep),
    ResumeThrow(ValueRep),
    TimerSleepDone,
}

enum TaskOutcomeRep {
    Ok(ValueRep),
    Thrown(ValueRep),
}

// NOTE: module paths are generated from WIT package/interface names.
// If these paths change due to WIT refactors, this smoke harness should be
// updated accordingly.
use crate::exports::flix::runtime::runtime::{
    Ctx, CtxBorrow, Exec, FileAccessTimeReq, FileAppendBytesReq, FileAppendReq, FileCreationTimeReq,
    FileExistsReq, FileIsDirectoryReq, FileIsExecutableReq, FileIsReadableReq,
    FileIsRegularFileReq, FileIsSymbolicLinkReq, FileIsWritableReq, FileListReq, FileMkdirReq,
    FileMkdirsReq, FileMkTempDirReq, FileModificationTimeReq, FileReadBytesReq, FileReadLinesReq,
    FileReadReq, FileSizeReq, FileTruncateReq, FileWriteBytesReq, FileWriteReq, Guest, GuestCtx,
    GuestSuspension, GuestValue, HttpHeader, HttpRequestReq, HttpResponse, IoError, OpRequest,
    ProcessEnvVar, ProcessExecReq, ProcessExitValueReq, ProcessIsAliveReq, ProcessPidReq,
    ProcessReleaseReq, ProcessStderrReadReq, ProcessStdinWriteReq, ProcessStopReq,
    ProcessStdoutReadReq, ProcessWaitForReq, ProcessWaitForTimeoutReq, Suspension,
    SuspensionBorrow, SuspensionInfo, SuspendedExec, TaskOutcome, TcpServerAcceptReq,
    TcpServerBindReq, TcpServerCloseReq, TcpServerLocalPortReq, TcpSocketCloseReq,
    TcpSocketConnectReq, TcpSocketReadReq, TcpSocketWriteReq, TimerSleepReq, UnknownReq, Value,
    ValueBorrow,
};
use crate::flix::sys::sys::{has_capability, log, random_bytes, time_now_ms, Capability, LogLevel};

fn fresh_task_id(state: &mut CtxState) -> u64 {
    state.next_task_id = state.next_task_id.wrapping_add(1);
    state.next_task_id
}

fn clone_args(args: Vec<ValueBorrow<'_>>) -> Vec<ValueRep> {
    args.into_iter()
        .map(|a| a.get::<ValueRep>().clone())
        .collect()
}

fn resume_blocked_task(
    ctx: CtxBorrow<'_>,
    s: Suspension,
    is_expected: impl FnOnce(SuspensionReqRep) -> bool,
    step: TaskStep,
    label: &'static str,
) {
    let rep = s.get::<SuspensionRep>();
    let task_id = rep.task_id;
    if !is_expected(rep.req) {
        panic!("{label} called on unexpected suspension request");
    }

    let ctx_rep = ctx.get::<CtxRep>();
    let mut state = ctx_rep.state.borrow_mut();
    let Some(task) = state.tasks.get_mut(&task_id) else {
        panic!("{label} for unknown task-id={task_id}");
    };

    let TaskState::Blocked = task.state else {
        panic!("{label} for task-id={task_id} that is not blocked");
    };

    task.state = TaskState::Ready(step);
    state.ready.push_back(task_id);
}

fn run_one_task(state: &mut CtxState, task_id: u64) -> Option<Suspension> {
    let task = state.tasks.get_mut(&task_id)?;

    let state = std::mem::replace(&mut task.state, TaskState::Poison);
    let (new_state, new_suspension) = match state {
        TaskState::Ready(step) => match step {
            TaskStep::Start => match (task.def_id, task.args.as_slice()) {
                // def 0: return "hello"
                (0, []) => (
                    TaskState::Completed {
                        outcome: TaskOutcomeRep::Ok(ValueRep::String(
                            "hello from flix-smoke".to_string(),
                        )),
                        consumed: false,
                    },
                    None,
                ),
                // def 1: add two i32s
                (1, [ValueRep::I32(a), ValueRep::I32(b)]) => (
                    TaskState::Completed {
                        outcome: TaskOutcomeRep::Ok(ValueRep::I32(a.wrapping_add(*b))),
                        consumed: false,
                    },
                    None,
                ),
                // def 2: suspend with a known eff/op id pair.
                (2, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 10,
                        op_id: 20,
                        req: SuspensionReqRep::Unknown,
                    })),
                ),
                // def 4: typed host op (timer-sleep) then return 123.
                (4, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 11,
                        op_id: 21,
                        req: SuspensionReqRep::TimerSleep { ms: 5 },
                    })),
                ),
                // def 5: typed host op (http-request) then return response body.
                (5, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 12,
                        op_id: 22,
                        req: SuspensionReqRep::HttpRequest,
                    })),
                ),
                // def 6: typed host op (http-request) then throw error message.
                (6, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 12,
                        op_id: 22,
                        req: SuspensionReqRep::HttpRequest,
                    })),
                ),
                // def 7: typed host op (tcp-socket-connect) then return socket id.
                (7, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 23,
                        req: SuspensionReqRep::TcpSocketConnect,
                    })),
                ),
                // def 8: typed host op (tcp-socket-connect) then throw error message.
                (8, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 23,
                        req: SuspensionReqRep::TcpSocketConnect,
                    })),
                ),
                // def 9: typed host op (tcp-socket-read) then return byte count.
                (9, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 24,
                        req: SuspensionReqRep::TcpSocketRead,
                    })),
                ),
                // def 10: typed host op (tcp-socket-write) then return bytes written.
                (10, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 25,
                        req: SuspensionReqRep::TcpSocketWrite,
                    })),
                ),
                // def 11: typed host op (tcp-socket-close) then return "closed".
                (11, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 26,
                        req: SuspensionReqRep::TcpSocketClose,
                    })),
                ),
                // def 12: typed host op (tcp-server-bind) then return server id.
                (12, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 27,
                        req: SuspensionReqRep::TcpServerBind,
                    })),
                ),
                // def 13: typed host op (tcp-server-accept) then return socket id.
                (13, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 28,
                        req: SuspensionReqRep::TcpServerAccept,
                    })),
                ),
                // def 14: typed host op (tcp-server-local-port) then return port.
                (14, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 29,
                        req: SuspensionReqRep::TcpServerLocalPort,
                    })),
                ),
                // def 15: typed host op (tcp-server-close) then return "server-closed".
                (15, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 13,
                        op_id: 30,
                        req: SuspensionReqRep::TcpServerClose,
                    })),
                ),
                // def 16: typed host op (file-exists) then return predicate result.
                (16, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 31,
                        req: SuspensionReqRep::FileExists,
                    })),
                ),
                // def 17: typed host op (file-size) then return size.
                (17, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 32,
                        req: SuspensionReqRep::FileSize,
                    })),
                ),
                // def 18: typed host op (file-read) then return data.
                (18, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 33,
                        req: SuspensionReqRep::FileRead,
                    })),
                ),
                // def 19: typed host op (file-read-lines) then return line count.
                (19, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 34,
                        req: SuspensionReqRep::FileReadLines,
                    })),
                ),
                // def 20: typed host op (file-read-bytes) then return byte count.
                (20, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 35,
                        req: SuspensionReqRep::FileReadBytes,
                    })),
                ),
                // def 21: typed host op (file-list) then return entry count.
                (21, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 36,
                        req: SuspensionReqRep::FileList,
                    })),
                ),
                // def 22: typed host op (file-write) then return "write-ok".
                (22, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 37,
                        req: SuspensionReqRep::FileWrite,
                    })),
                ),
                // def 54: typed host op (file-list) on a missing path; should throw NotDirectory.
                (54, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 36,
                        req: SuspensionReqRep::FileList,
                    })),
                ),
                // def 55: typed host op (file-read) on a missing path; should throw Other.
                (55, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 33,
                        req: SuspensionReqRep::FileRead,
                    })),
                ),
                // def 23: typed host op (file-write-bytes) then throw error message.
                (23, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 38,
                        req: SuspensionReqRep::FileWriteBytes,
                    })),
                ),
                // def 24: typed host op (file-mk-temp-dir) then return path.
                (24, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 39,
                        req: SuspensionReqRep::FileMkTempDir,
                    })),
                ),
                // def 25: typed host op (process-exec) then return process id.
                (25, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 40,
                        req: SuspensionReqRep::ProcessExec,
                    })),
                ),
                // def 26: typed host op (process-exec) then throw error message.
                (26, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 40,
                        req: SuspensionReqRep::ProcessExec,
                    })),
                ),
                // def 27: typed host op (process-pid) then return pid.
                (27, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 41,
                        req: SuspensionReqRep::ProcessPid,
                    })),
                ),
                // def 28: typed host op (process-wait-for) then return exit code.
                (28, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 42,
                        req: SuspensionReqRep::ProcessWaitFor,
                    })),
                ),
                // def 29: typed host op (process-wait-for-timeout) then return finished status.
                (29, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 43,
                        req: SuspensionReqRep::ProcessWaitForTimeout,
                    })),
                ),
                // def 30: typed host op (process-stdin-write) then return bytes written.
                (30, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 44,
                        req: SuspensionReqRep::ProcessStdinWrite,
                    })),
                ),
                // def 31: typed host op (process-stdout-read) then return byte count.
                (31, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 45,
                        req: SuspensionReqRep::ProcessStdoutRead,
                    })),
                ),
                // def 32: typed host op (process-stderr-read) then return byte count.
                (32, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 46,
                        req: SuspensionReqRep::ProcessStderrRead,
                    })),
                ),
                // def 33: typed host op (process-release) then return "released".
                (33, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 47,
                        req: SuspensionReqRep::ProcessRelease,
                    })),
                ),
                // def 34: typed host op (file-is-directory) then return predicate result.
                (34, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 48,
                        req: SuspensionReqRep::FileIsDirectory,
                    })),
                ),
                // def 35: typed host op (file-is-regular-file) then return predicate result.
                (35, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 49,
                        req: SuspensionReqRep::FileIsRegularFile,
                    })),
                ),
                // def 36: typed host op (file-is-readable) then return predicate result.
                (36, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 50,
                        req: SuspensionReqRep::FileIsReadable,
                    })),
                ),
                // def 37: typed host op (file-is-symbolic-link) then return predicate result.
                (37, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 51,
                        req: SuspensionReqRep::FileIsSymbolicLink,
                    })),
                ),
                // def 38: typed host op (file-is-writable) then return predicate result.
                (38, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 52,
                        req: SuspensionReqRep::FileIsWritable,
                    })),
                ),
                // def 39: typed host op (file-is-executable) then return predicate result.
                (39, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 53,
                        req: SuspensionReqRep::FileIsExecutable,
                    })),
                ),
                // def 40: typed host op (file-access-time) then return access time.
                (40, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 54,
                        req: SuspensionReqRep::FileAccessTime,
                    })),
                ),
                // def 41: typed host op (file-creation-time) then return creation time.
                (41, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 55,
                        req: SuspensionReqRep::FileCreationTime,
                    })),
                ),
                // def 42: typed host op (file-modification-time) then return modification time.
                (42, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 56,
                        req: SuspensionReqRep::FileModificationTime,
                    })),
                ),
                // def 43: typed host op (file-write-bytes) then return "write-bytes-ok".
                (43, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 38,
                        req: SuspensionReqRep::FileWriteBytes,
                    })),
                ),
                // def 44: typed host op (file-append) then return "append-ok".
                (44, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 57,
                        req: SuspensionReqRep::FileAppend,
                    })),
                ),
                // def 45: typed host op (file-append-bytes) then return "append-bytes-ok".
                (45, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 58,
                        req: SuspensionReqRep::FileAppendBytes,
                    })),
                ),
                // def 46: typed host op (file-truncate) then return "truncate-ok".
                (46, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 59,
                        req: SuspensionReqRep::FileTruncate,
                    })),
                ),
                // def 47: typed host op (file-mkdir) then return "mkdir-ok".
                (47, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 60,
                        req: SuspensionReqRep::FileMkdir,
                    })),
                ),
                // def 48: typed host op (file-mkdirs) then return "mkdirs-ok".
                (48, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 14,
                        op_id: 61,
                        req: SuspensionReqRep::FileMkdirs,
                    })),
                ),
                // def 49: typed host op (process-exit-value) then return exit code.
                (49, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 62,
                        req: SuspensionReqRep::ProcessExitValue,
                    })),
                ),
                // def 50: typed host op (process-is-alive) then return alive flag.
                (50, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 63,
                        req: SuspensionReqRep::ProcessIsAlive,
                    })),
                ),
                // def 51: typed host op (process-stop) then return "stopped".
                (51, []) => (
                    TaskState::Blocked,
                    Some(Suspension::new(SuspensionRep {
                        task_id,
                        eff_id: 15,
                        op_id: 64,
                        req: SuspensionReqRep::ProcessStop,
                    })),
                ),
                // def 52: TCP roundtrip on localhost (bind port=0, connect, accept, ping, close).
                (52, []) => {
                    if task.tcp_roundtrip.is_none() {
                        task.tcp_roundtrip = Some(TcpRoundtripScratch::new());
                    }

                    let scratch = task
                        .tcp_roundtrip
                        .as_mut()
                        .expect("tcp-roundtrip scratch must be present");

                    let missing = |what: &'static str| {
                        (
                            TaskState::Completed {
                                outcome: TaskOutcomeRep::Thrown(ValueRep::String(format!(
                                    "tcp-roundtrip: missing {what}"
                                ))),
                                consumed: false,
                            },
                            None,
                        )
                    };

                    match scratch.stage {
                        TcpRoundtripStage::Bind => (
                            TaskState::Blocked,
                            Some(Suspension::new(SuspensionRep {
                                task_id,
                                eff_id: 13,
                                op_id: 27,
                                req: SuspensionReqRep::TcpServerBind,
                            })),
                        ),
                        TcpRoundtripStage::LocalPort => {
                            if scratch.server_id.is_none() {
                                missing("server_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 29,
                                        req: SuspensionReqRep::TcpServerLocalPort,
                                    })),
                                )
                            }
                        }
                        TcpRoundtripStage::Connect => {
                            if scratch.port.is_none() {
                                missing("port")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 23,
                                        req: SuspensionReqRep::TcpSocketConnect,
                                    })),
                                )
                            }
                        }
                        TcpRoundtripStage::Accept => {
                            if scratch.server_id.is_none() {
                                missing("server_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 28,
                                        req: SuspensionReqRep::TcpServerAccept,
                                    })),
                                )
                            }
                        }
                        TcpRoundtripStage::ClientWrite => {
                            if scratch.client_socket_id.is_none() {
                                missing("client_socket_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 25,
                                        req: SuspensionReqRep::TcpSocketWrite,
                                    })),
                                )
                            }
                        }
                        TcpRoundtripStage::ServerRead => {
                            if scratch.server_socket_id.is_none() {
                                missing("server_socket_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 24,
                                        req: SuspensionReqRep::TcpSocketRead,
                                    })),
                                )
                            }
                        }
                        TcpRoundtripStage::CloseServerSocket
                        | TcpRoundtripStage::CloseClientSocket => (
                            TaskState::Blocked,
                            Some(Suspension::new(SuspensionRep {
                                task_id,
                                eff_id: 13,
                                op_id: 26,
                                req: SuspensionReqRep::TcpSocketClose,
                            })),
                        ),
                        TcpRoundtripStage::CloseServer => {
                            if scratch.server_id.is_none() {
                                missing("server_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 13,
                                        op_id: 30,
                                        req: SuspensionReqRep::TcpServerClose,
                                    })),
                                )
                            }
                        }
                    }
                }
                // def 53: Process roundtrip (spawn node, ping over stdio, wait, release).
                (53, []) => {
                    if task.proc_roundtrip.is_none() {
                        task.proc_roundtrip = Some(ProcessRoundtripScratch::new());
                    }

                    let scratch = task
                        .proc_roundtrip
                        .as_mut()
                        .expect("process-roundtrip scratch must be present");

                    let missing = |what: &'static str| {
                        (
                            TaskState::Completed {
                                outcome: TaskOutcomeRep::Thrown(ValueRep::String(format!(
                                    "process-roundtrip: missing {what}"
                                ))),
                                consumed: false,
                            },
                            None,
                        )
                    };

                    match scratch.stage {
                        ProcessRoundtripStage::Exec => (
                            TaskState::Blocked,
                            Some(Suspension::new(SuspensionRep {
                                task_id,
                                eff_id: 15,
                                op_id: 40,
                                req: SuspensionReqRep::ProcessExec,
                            })),
                        ),
                        ProcessRoundtripStage::Pid => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 41,
                                        req: SuspensionReqRep::ProcessPid,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::IsAliveBefore | ProcessRoundtripStage::IsAliveAfter => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 63,
                                        req: SuspensionReqRep::ProcessIsAlive,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::WaitTimeout => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 43,
                                        req: SuspensionReqRep::ProcessWaitForTimeout,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::StdoutReady | ProcessRoundtripStage::StdoutOk => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 45,
                                        req: SuspensionReqRep::ProcessStdoutRead,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::StderrErr => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 46,
                                        req: SuspensionReqRep::ProcessStderrRead,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::StdinWrite => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 44,
                                        req: SuspensionReqRep::ProcessStdinWrite,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::WaitFor => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 42,
                                        req: SuspensionReqRep::ProcessWaitFor,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::ExitValue => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 62,
                                        req: SuspensionReqRep::ProcessExitValue,
                                    })),
                                )
                            }
                        }
                        ProcessRoundtripStage::Release => {
                            if scratch.process_id.is_none() {
                                missing("process_id")
                            } else {
                                (
                                    TaskState::Blocked,
                                    Some(Suspension::new(SuspensionRep {
                                        task_id,
                                        eff_id: 15,
                                        op_id: 47,
                                        req: SuspensionReqRep::ProcessRelease,
                                    })),
                                )
                            }
                        }
                    }
                }
                // def 3: throw a simple string payload.
                (3, []) => (
                    TaskState::Completed {
                        outcome: TaskOutcomeRep::Thrown(ValueRep::String(
                            "thrown from flix-smoke".to_string(),
                        )),
                        consumed: false,
                    },
                    None,
                ),
                _ => (
                    TaskState::Completed {
                        outcome: TaskOutcomeRep::Thrown(ValueRep::String(
                            "unsupported def-id/arity".to_string(),
                        )),
                        consumed: false,
                    },
                    None,
                ),
            },
            TaskStep::ResumeOk(v) => (
                TaskState::Completed {
                    outcome: TaskOutcomeRep::Ok(v),
                    consumed: false,
                },
                None,
            ),
            TaskStep::ResumeThrow(e) => (
                TaskState::Completed {
                    outcome: TaskOutcomeRep::Thrown(e),
                    consumed: false,
                },
                None,
            ),
            TaskStep::TimerSleepDone => (
                TaskState::Completed {
                    outcome: TaskOutcomeRep::Ok(ValueRep::I32(123)),
                    consumed: false,
                },
                None,
            ),
        },
        TaskState::Blocked => (TaskState::Blocked, None),
        TaskState::Completed { outcome, consumed } => (
            TaskState::Completed { outcome, consumed },
            None,
        ),
        TaskState::Poison => panic!("task in poison state"),
    };

    task.state = new_state;
    new_suspension
}

impl Guest for Component {
    type Ctx = CtxRep;
    type Value = ValueRep;
    type Suspension = SuspensionRep;

    fn new_ctx() -> Ctx {
        let now = time_now_ms();
        let http_cap = has_capability(Capability::Http);
        let bytes = random_bytes(4);
        log(
            LogLevel::Info,
            &format!(
                "flix-smoke-guest: new-ctx now-ms={now} http-cap={http_cap} rand-bytes-len={}",
                bytes.len()
            ),
        );
        Ctx::new(CtxRep {
            id: 1,
            state: RefCell::new(CtxState::default()),
        })
    }

    fn invoke(ctx: CtxBorrow<'_>, def_id: u64, args: Vec<ValueBorrow<'_>>) -> Exec {
        let _ = ctx.get::<CtxRep>().id;
        log(
            LogLevel::Info,
            &format!("flix-smoke-guest: invoke def-id={def_id} args={}", args.len()),
        );

        // Keep `invoke` usable for “pure-ish” direct calls, but ensure that if we ever
        // suspend we return a `task-id` that the host can `poll-task`.
        match (def_id, args.as_slice()) {
            // Fast-path for the simple smoke defs.
            (0, []) => Exec::Ok(Self::box_string(ctx, "hello from flix-smoke".to_string())),
            (1, [a, b]) => {
                let a = match a.get::<ValueRep>() {
                    ValueRep::I32(x) => *x,
                    _ => return Exec::Thrown(Self::box_string(ctx, "arg0 not i32".to_string())),
                };
                let b = match b.get::<ValueRep>() {
                    ValueRep::I32(x) => *x,
                    _ => return Exec::Thrown(Self::box_string(ctx, "arg1 not i32".to_string())),
                };
                Exec::Ok(Self::box_i32(ctx, a.wrapping_add(b)))
            }
            (2, []) => {
                let ctx_rep = ctx.get::<CtxRep>();
                let mut state = ctx_rep.state.borrow_mut();

                let task_id = fresh_task_id(&mut state);
                let task = TaskRep {
                    def_id,
                    args: Vec::new(),
                    state: TaskState::Blocked,
                    tcp_roundtrip: None,
                    proc_roundtrip: None,
                };
                state.tasks.insert(task_id, task);

                let suspension = Suspension::new(SuspensionRep {
                    task_id,
                    eff_id: 10,
                    op_id: 20,
                    req: SuspensionReqRep::Unknown,
                });
                Exec::Suspended(SuspendedExec { task: task_id, suspension })
            }
            (4, []) => {
                let ctx_rep = ctx.get::<CtxRep>();
                let mut state = ctx_rep.state.borrow_mut();

                let task_id = fresh_task_id(&mut state);
                let task = TaskRep {
                    def_id,
                    args: Vec::new(),
                    state: TaskState::Blocked,
                    tcp_roundtrip: None,
                    proc_roundtrip: None,
                };
                state.tasks.insert(task_id, task);

                let suspension = Suspension::new(SuspensionRep {
                    task_id,
                    eff_id: 11,
                    op_id: 21,
                    req: SuspensionReqRep::TimerSleep { ms: 5 },
                });
                Exec::Suspended(SuspendedExec { task: task_id, suspension })
            }
            (5, []) | (6, []) => {
                let ctx_rep = ctx.get::<CtxRep>();
                let mut state = ctx_rep.state.borrow_mut();

                let task_id = fresh_task_id(&mut state);
                let task = TaskRep {
                    def_id,
                    args: Vec::new(),
                    state: TaskState::Blocked,
                    tcp_roundtrip: None,
                    proc_roundtrip: None,
                };
                state.tasks.insert(task_id, task);

                let suspension = Suspension::new(SuspensionRep {
                    task_id,
                    eff_id: 12,
                    op_id: 22,
                    req: SuspensionReqRep::HttpRequest,
                });
                Exec::Suspended(SuspendedExec { task: task_id, suspension })
            }
            (7, []) | (8, []) => {
                let ctx_rep = ctx.get::<CtxRep>();
                let mut state = ctx_rep.state.borrow_mut();

                let task_id = fresh_task_id(&mut state);
                let task = TaskRep {
                    def_id,
                    args: Vec::new(),
                    state: TaskState::Blocked,
                    tcp_roundtrip: None,
                    proc_roundtrip: None,
                };
                state.tasks.insert(task_id, task);

                let suspension = Suspension::new(SuspensionRep {
                    task_id,
                    eff_id: 13,
                    op_id: 23,
                    req: SuspensionReqRep::TcpSocketConnect,
                });
                Exec::Suspended(SuspendedExec { task: task_id, suspension })
            }
            (3, []) => Exec::Thrown(Self::box_string(ctx, "thrown from flix-smoke".to_string())),
            _ => Exec::Thrown(Self::box_string(ctx, "unsupported def-id/arity".to_string())),
        }
    }

    fn start_task(ctx: CtxBorrow<'_>, def_id: u64, args: Vec<ValueBorrow<'_>>) -> u64 {
        log(LogLevel::Info, &format!("flix-smoke-guest: start-task def-id={def_id}"));

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let task_id = fresh_task_id(&mut state);
        let task = TaskRep {
            def_id,
            args: clone_args(args),
            state: TaskState::Ready(TaskStep::Start),
            tcp_roundtrip: None,
            proc_roundtrip: None,
        };
        state.tasks.insert(task_id, task);
        state.ready.push_back(task_id);
        task_id
    }

    fn sched_step(ctx: CtxBorrow<'_>, budget: u32) -> Vec<Suspension> {
        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        log(
            LogLevel::Info,
            &format!(
                "flix-smoke-guest: sched-step budget={budget} ready={}",
                state.ready.len()
            ),
        );

        let mut out = Vec::new();
        let mut remaining = budget;
        while remaining > 0 {
            let Some(task_id) = state.ready.pop_front() else {
                break;
            };

            let suspension = run_one_task(&mut state, task_id);
            if let Some(s) = suspension {
                out.push(s);
            }

            remaining -= 1;
        }
        out
    }

    fn poll_task(ctx: CtxBorrow<'_>, task_id: u64) -> Option<TaskOutcome> {
        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            return None;
        };

        match &mut task.state {
            TaskState::Completed { outcome, consumed } => {
                if *consumed {
                    return None;
                }
                *consumed = true;

                let outcome = match outcome {
                    TaskOutcomeRep::Ok(v) => TaskOutcome::Ok(Value::new(v.clone())),
                    TaskOutcomeRep::Thrown(e) => TaskOutcome::Thrown(Value::new(e.clone())),
                };
                Some(outcome)
            }
            _ => None,
        }
    }

    fn suspension_peek(_ctx: CtxBorrow<'_>, s: SuspensionBorrow<'_>) -> SuspensionInfo {
        let s = s.get::<SuspensionRep>();
        SuspensionInfo {
            eff_id: s.eff_id,
            op_id: s.op_id,
        }
    }

    fn suspension_request(ctx: CtxBorrow<'_>, s: SuspensionBorrow<'_>) -> OpRequest {
        let s = s.get::<SuspensionRep>();
        let (
            def_id,
            tcp_stage,
            tcp_server_id,
            tcp_port,
            tcp_client_socket_id,
            tcp_server_socket_id,
            _proc_stage,
            proc_process_id,
        ) = {
            let ctx_rep = ctx.get::<CtxRep>();
            let state = ctx_rep.state.borrow();
            let task = state.tasks.get(&s.task_id);
            let def_id = task.map(|t| t.def_id).unwrap_or(0);

            let (tcp_stage, tcp_server_id, tcp_port, tcp_client_socket_id, tcp_server_socket_id) =
                task.and_then(|t| t.tcp_roundtrip.as_ref()).map_or(
                    (None, None, None, None, None),
                    |tcp| {
                        (
                            Some(tcp.stage),
                            tcp.server_id,
                            tcp.port,
                            tcp.client_socket_id,
                            tcp.server_socket_id,
                        )
                    },
                );

            let (_proc_stage, proc_process_id) = task
                .and_then(|t| t.proc_roundtrip.as_ref())
                .map_or((None, None), |p| (Some(p.stage), p.process_id));

            (
                def_id,
                tcp_stage,
                tcp_server_id,
                tcp_port,
                tcp_client_socket_id,
                tcp_server_socket_id,
                _proc_stage,
                proc_process_id,
            )
        };
        match s.req {
            SuspensionReqRep::TimerSleep { ms } => {
                OpRequest::TimerSleep(TimerSleepReq { ms })
            }
            SuspensionReqRep::HttpRequest => OpRequest::HttpRequest(HttpRequestReq {
                method: "GET".to_string(),
                url: "https://example.com/hello".to_string(),
                headers: vec![HttpHeader {
                    name: "x-req".to_string(),
                    value: "abc".to_string(),
                }],
                body: None,
            }),
            SuspensionReqRep::FileExists => OpRequest::FileExists(FileExistsReq {
                path: "fixtures/hello.txt".to_string(),
            }),
            SuspensionReqRep::FileIsDirectory => OpRequest::FileIsDirectory(FileIsDirectoryReq {
                path: "fixtures".to_string(),
            }),
            SuspensionReqRep::FileIsRegularFile => {
                OpRequest::FileIsRegularFile(FileIsRegularFileReq {
                    path: "fixtures/hello.txt".to_string(),
                })
            }
            SuspensionReqRep::FileIsReadable => OpRequest::FileIsReadable(FileIsReadableReq {
                path: "fixtures/hello.txt".to_string(),
            }),
            SuspensionReqRep::FileIsSymbolicLink => {
                OpRequest::FileIsSymbolicLink(FileIsSymbolicLinkReq {
                    path: "fixtures/link.txt".to_string(),
                })
            }
            SuspensionReqRep::FileIsWritable => OpRequest::FileIsWritable(FileIsWritableReq {
                path: "fixtures/hello.txt".to_string(),
            }),
            SuspensionReqRep::FileIsExecutable => {
                OpRequest::FileIsExecutable(FileIsExecutableReq {
                    path: "fixtures/bin".to_string(),
                })
            }
            SuspensionReqRep::FileAccessTime => OpRequest::FileAccessTime(FileAccessTimeReq {
                path: "fixtures/hello.txt".to_string(),
            }),
            SuspensionReqRep::FileCreationTime => {
                OpRequest::FileCreationTime(FileCreationTimeReq {
                    path: "fixtures/hello.txt".to_string(),
                })
            }
            SuspensionReqRep::FileModificationTime => {
                OpRequest::FileModificationTime(FileModificationTimeReq {
                    path: "fixtures/hello.txt".to_string(),
                })
            }
            SuspensionReqRep::FileSize => OpRequest::FileSize(FileSizeReq {
                path: "fixtures/hello.txt".to_string(),
            }),
            SuspensionReqRep::FileRead => OpRequest::FileRead(FileReadReq {
                path: if def_id == 55 {
                    "fixtures/missing.txt".to_string()
                } else {
                    "fixtures/hello.txt".to_string()
                },
            }),
            SuspensionReqRep::FileReadLines => OpRequest::FileReadLines(FileReadLinesReq {
                path: "fixtures/lines.txt".to_string(),
            }),
            SuspensionReqRep::FileReadBytes => OpRequest::FileReadBytes(FileReadBytesReq {
                path: "fixtures/bytes.bin".to_string(),
            }),
            SuspensionReqRep::FileList => OpRequest::FileList(FileListReq {
                path: if def_id == 54 {
                    "fixtures/missing".to_string()
                } else {
                    "fixtures".to_string()
                },
            }),
            SuspensionReqRep::FileWrite => OpRequest::FileWrite(FileWriteReq {
                path: "out/write.txt".to_string(),
                data: "hello".to_string(),
            }),
            SuspensionReqRep::FileWriteBytes => OpRequest::FileWriteBytes(FileWriteBytesReq {
                path: "out/write.bin".to_string(),
                bytes: vec![1, 2, 3],
            }),
            SuspensionReqRep::FileAppend => OpRequest::FileAppend(FileAppendReq {
                path: "out/append.txt".to_string(),
                data: "hello".to_string(),
            }),
            SuspensionReqRep::FileAppendBytes => OpRequest::FileAppendBytes(FileAppendBytesReq {
                path: "out/append.bin".to_string(),
                bytes: vec![4, 5, 6],
            }),
            SuspensionReqRep::FileTruncate => OpRequest::FileTruncate(FileTruncateReq {
                path: "out/trunc.txt".to_string(),
            }),
            SuspensionReqRep::FileMkdir => OpRequest::FileMkdir(FileMkdirReq {
                path: "out/dir".to_string(),
            }),
            SuspensionReqRep::FileMkdirs => OpRequest::FileMkdirs(FileMkdirsReq {
                path: "out/dir/nested".to_string(),
            }),
            SuspensionReqRep::FileMkTempDir => OpRequest::FileMkTempDir(FileMkTempDirReq {
                prefix: "flix".to_string(),
            }),
            SuspensionReqRep::ProcessExec => {
                if def_id == 53 {
                    // Deterministic cross-platform process for the JS runner smoke:
                    // - print "ready\n"
                    // - wait for "go\n" on stdin
                    // - print "ok\n" to stdout and "err\n" to stderr
                    // - exit(7)
                    let script = r#"
process.stdout.write("ready\n");
process.stdin.setEncoding("utf8");
let buf = "";
process.stdin.on("data", (c) => {
  buf += c;
  if (buf.includes("go\n")) {
    process.stdout.write("ok\n");
    process.stderr.write("err\n");
    process.exit(7);
  }
});
process.stdin.resume();
"#
                    .trim()
                    .to_string();

                    OpRequest::ProcessExec(ProcessExecReq {
                        argv: vec!["node".to_string(), "-e".to_string(), script],
                        cwd: None,
                        env: vec![],
                    })
                } else {
                    OpRequest::ProcessExec(ProcessExecReq {
                        argv: vec!["echo".to_string(), "hello".to_string()],
                        cwd: Some("tmp".to_string()),
                        env: vec![ProcessEnvVar {
                            key: "FOO".to_string(),
                            value: "BAR".to_string(),
                        }],
                    })
                }
            }
            SuspensionReqRep::ProcessExitValue => OpRequest::ProcessExitValue(ProcessExitValueReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::ProcessIsAlive => OpRequest::ProcessIsAlive(ProcessIsAliveReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::ProcessPid => OpRequest::ProcessPid(ProcessPidReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::ProcessStop => OpRequest::ProcessStop(ProcessStopReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::ProcessWaitFor => OpRequest::ProcessWaitFor(ProcessWaitForReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::ProcessWaitForTimeout => OpRequest::ProcessWaitForTimeout(
                ProcessWaitForTimeoutReq {
                    process_id: if def_id == 53 {
                        proc_process_id.expect("process-roundtrip: missing process_id")
                    } else {
                        77
                    },
                    timeout_ms: if def_id == 53 { 0 } else { 1000 },
                },
            ),
            SuspensionReqRep::ProcessStdinWrite => OpRequest::ProcessStdinWrite(ProcessStdinWriteReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
                bytes: if def_id == 53 {
                    b"go\n".to_vec()
                } else {
                    vec![1, 2, 3]
                },
            }),
            SuspensionReqRep::ProcessStdoutRead => OpRequest::ProcessStdoutRead(ProcessStdoutReadReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
                max_bytes: if def_id == 53 { 64 } else { 4 },
            }),
            SuspensionReqRep::ProcessStderrRead => OpRequest::ProcessStderrRead(ProcessStderrReadReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
                max_bytes: if def_id == 53 { 64 } else { 4 },
            }),
            SuspensionReqRep::ProcessRelease => OpRequest::ProcessRelease(ProcessReleaseReq {
                process_id: if def_id == 53 {
                    proc_process_id.expect("process-roundtrip: missing process_id")
                } else {
                    77
                },
            }),
            SuspensionReqRep::TcpSocketConnect => {
                let port = if def_id == 52 {
                    tcp_port.expect("tcp-roundtrip: missing port")
                } else {
                    8080
                };
                OpRequest::TcpSocketConnect(TcpSocketConnectReq {
                    ip: vec![127, 0, 0, 1],
                    port,
                })
            }
            SuspensionReqRep::TcpSocketRead => OpRequest::TcpSocketRead(TcpSocketReadReq {
                socket_id: if def_id == 52 {
                    tcp_server_socket_id.expect("tcp-roundtrip: missing server_socket_id")
                } else {
                    99
                },
                max_bytes: if def_id == 52 { 64 } else { 4 },
            }),
            SuspensionReqRep::TcpSocketWrite => OpRequest::TcpSocketWrite(TcpSocketWriteReq {
                socket_id: if def_id == 52 {
                    tcp_client_socket_id.expect("tcp-roundtrip: missing client_socket_id")
                } else {
                    99
                },
                bytes: if def_id == 52 {
                    b"ping".to_vec()
                } else {
                    vec![7, 8, 9]
                },
            }),
            SuspensionReqRep::TcpSocketClose => OpRequest::TcpSocketClose(TcpSocketCloseReq {
                socket_id: if def_id == 52 {
                    match tcp_stage.expect("tcp-roundtrip: missing stage") {
                        TcpRoundtripStage::CloseServerSocket => tcp_server_socket_id
                            .expect("tcp-roundtrip: missing server_socket_id"),
                        TcpRoundtripStage::CloseClientSocket => tcp_client_socket_id
                            .expect("tcp-roundtrip: missing client_socket_id"),
                        _ => panic!("tcp-roundtrip: unexpected stage for socket-close"),
                    }
                } else {
                    99
                },
            }),
            SuspensionReqRep::TcpServerBind => OpRequest::TcpServerBind(TcpServerBindReq {
                ip: vec![127, 0, 0, 1],
                port: if def_id == 52 { 0 } else { 8080 },
            }),
            SuspensionReqRep::TcpServerAccept => OpRequest::TcpServerAccept(TcpServerAcceptReq {
                server_id: if def_id == 52 {
                    tcp_server_id.expect("tcp-roundtrip: missing server_id")
                } else {
                    55
                },
            }),
            SuspensionReqRep::TcpServerLocalPort => {
                OpRequest::TcpServerLocalPort(TcpServerLocalPortReq {
                    server_id: if def_id == 52 {
                        tcp_server_id.expect("tcp-roundtrip: missing server_id")
                    } else {
                        55
                    },
                })
            }
            SuspensionReqRep::TcpServerClose => OpRequest::TcpServerClose(TcpServerCloseReq {
                server_id: if def_id == 52 {
                    tcp_server_id.expect("tcp-roundtrip: missing server_id")
                } else {
                    55
                },
            }),
            SuspensionReqRep::Unknown => OpRequest::Unknown(UnknownReq {
                eff_id: s.eff_id,
                op_id: s.op_id,
            }),
        }
    }

    fn resume_ok(ctx: CtxBorrow<'_>, s: Suspension, v: ValueBorrow<'_>) {
        log(LogLevel::Info, "flix-smoke-guest: resume-ok");

        let task_id = s.get::<SuspensionRep>().task_id;
        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-ok for task-id={task_id} that is not blocked");
        };

        task.state = TaskState::Ready(TaskStep::ResumeOk(v.get::<ValueRep>().clone()));
        state.ready.push_back(task_id);
    }

    fn resume_throw(ctx: CtxBorrow<'_>, s: Suspension, e: ValueBorrow<'_>) {
        log(LogLevel::Info, "flix-smoke-guest: resume-throw");

        let task_id = s.get::<SuspensionRep>().task_id;
        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-throw for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-throw for task-id={task_id} that is not blocked");
        };

        task.state = TaskState::Ready(TaskStep::ResumeThrow(e.get::<ValueRep>().clone()));
        state.ready.push_back(task_id);
    }

    fn resume_timer_sleep(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-timer-sleep");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TimerSleep { .. } = rep.req else {
            panic!("resume-timer-sleep called on non timer-sleep suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-timer-sleep for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-timer-sleep for task-id={task_id} that is not blocked");
        };

        task.state = TaskState::Ready(TaskStep::TimerSleepDone);
        state.ready.push_back(task_id);
    }

    fn resume_http_ok(ctx: CtxBorrow<'_>, s: Suspension, resp: HttpResponse) {
        log(LogLevel::Info, "flix-smoke-guest: resume-http-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::HttpRequest = rep.req else {
            panic!("resume-http-ok called on non http-request suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-http-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-http-ok for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", resp.status, resp.body);
        task.state = match task.def_id {
            6 => TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out))),
            _ => TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out))),
        };
        state.ready.push_back(task_id);
    }

    fn resume_http_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-http-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::HttpRequest = rep.req else {
            panic!("resume-http-err called on non http-request suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-http-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-http-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_file_exists_ok(ctx: CtxBorrow<'_>, s: Suspension, exists: bool) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-exists-ok");
        let out = format!("exists={exists}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileExists),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-exists-ok",
        );
    }

    fn resume_file_exists_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-exists-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileExists),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-exists-err",
        );
    }

    fn resume_file_is_directory_ok(ctx: CtxBorrow<'_>, s: Suspension, is_directory: bool) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-is-directory-ok");
        let out = format!("is-directory={is_directory}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsDirectory),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-directory-ok",
        );
    }

    fn resume_file_is_directory_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-directory-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsDirectory),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-directory-err",
        );
    }

    fn resume_file_is_regular_file_ok(ctx: CtxBorrow<'_>, s: Suspension, is_regular_file: bool) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-regular-file-ok",
        );
        let out = format!("is-regular-file={is_regular_file}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsRegularFile),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-regular-file-ok",
        );
    }

    fn resume_file_is_regular_file_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-regular-file-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsRegularFile),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-regular-file-err",
        );
    }

    fn resume_file_is_readable_ok(ctx: CtxBorrow<'_>, s: Suspension, is_readable: bool) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-is-readable-ok");
        let out = format!("is-readable={is_readable}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsReadable),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-readable-ok",
        );
    }

    fn resume_file_is_readable_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-readable-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsReadable),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-readable-err",
        );
    }

    fn resume_file_is_symbolic_link_ok(
        ctx: CtxBorrow<'_>,
        s: Suspension,
        is_symbolic_link: bool,
    ) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-symbolic-link-ok",
        );
        let out = format!("is-symbolic-link={is_symbolic_link}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsSymbolicLink),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-symbolic-link-ok",
        );
    }

    fn resume_file_is_symbolic_link_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-symbolic-link-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsSymbolicLink),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-symbolic-link-err",
        );
    }

    fn resume_file_is_writable_ok(ctx: CtxBorrow<'_>, s: Suspension, is_writable: bool) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-is-writable-ok");
        let out = format!("is-writable={is_writable}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsWritable),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-writable-ok",
        );
    }

    fn resume_file_is_writable_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-writable-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsWritable),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-writable-err",
        );
    }

    fn resume_file_is_executable_ok(ctx: CtxBorrow<'_>, s: Suspension, is_executable: bool) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-executable-ok",
        );
        let out = format!("is-executable={is_executable}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsExecutable),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-is-executable-ok",
        );
    }

    fn resume_file_is_executable_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-is-executable-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileIsExecutable),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-is-executable-err",
        );
    }

    fn resume_file_access_time_ok(ctx: CtxBorrow<'_>, s: Suspension, ms: i64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-access-time-ok");
        let out = format!("access-ms={ms}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAccessTime),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-access-time-ok",
        );
    }

    fn resume_file_access_time_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-access-time-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAccessTime),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-access-time-err",
        );
    }

    fn resume_file_creation_time_ok(ctx: CtxBorrow<'_>, s: Suspension, ms: i64) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-creation-time-ok",
        );
        let out = format!("creation-ms={ms}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileCreationTime),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-creation-time-ok",
        );
    }

    fn resume_file_creation_time_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-creation-time-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileCreationTime),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-creation-time-err",
        );
    }

    fn resume_file_modification_time_ok(ctx: CtxBorrow<'_>, s: Suspension, ms: i64) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-modification-time-ok",
        );
        let out = format!("mod-ms={ms}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileModificationTime),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-modification-time-ok",
        );
    }

    fn resume_file_modification_time_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-modification-time-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileModificationTime),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-modification-time-err",
        );
    }

    fn resume_file_size_ok(ctx: CtxBorrow<'_>, s: Suspension, bytes: i64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-size-ok");
        let out = format!("size={bytes}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileSize),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-size-ok",
        );
    }

    fn resume_file_size_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-size-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileSize),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-size-err",
        );
    }

    fn resume_file_read_ok(ctx: CtxBorrow<'_>, s: Suspension, data: String) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-read-ok");
        let out = format!("read={data}");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileRead),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-read-ok",
        );
    }

    fn resume_file_read_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-read-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileRead),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-read-err",
        );
    }

    fn resume_file_read_lines_ok(ctx: CtxBorrow<'_>, s: Suspension, lines: Vec<String>) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-read-lines-ok",
        );
        let first = lines.first().map(String::as_str).unwrap_or("");
        let out = format!("lines={} first={first}", lines.len());
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileReadLines),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-read-lines-ok",
        );
    }

    fn resume_file_read_lines_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-read-lines-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileReadLines),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-read-lines-err",
        );
    }

    fn resume_file_read_bytes_ok(ctx: CtxBorrow<'_>, s: Suspension, bytes: Vec<u8>) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-read-bytes-ok",
        );
        let first = bytes.first().copied().unwrap_or(0);
        let out = format!("bytes={} first={first}", bytes.len());
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileReadBytes),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-read-bytes-ok",
        );
    }

    fn resume_file_read_bytes_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-read-bytes-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileReadBytes),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-read-bytes-err",
        );
    }

    fn resume_file_list_ok(ctx: CtxBorrow<'_>, s: Suspension, names: Vec<String>) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-list-ok");
        let first = names.first().map(String::as_str).unwrap_or("");
        let out = format!("list={} first={first}", names.len());
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileList),
            TaskStep::ResumeOk(ValueRep::String(out)),
            "resume-file-list-ok",
        );
    }

    fn resume_file_list_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-list-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileList),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-list-err",
        );
    }

    fn resume_file_write_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-write-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileWrite),
            TaskStep::ResumeOk(ValueRep::String("write-ok".to_string())),
            "resume-file-write-ok",
        );
    }

    fn resume_file_write_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-write-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileWrite),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-write-err",
        );
    }

    fn resume_file_write_bytes_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-write-bytes-ok",
        );
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileWriteBytes),
            TaskStep::ResumeOk(ValueRep::String("write-bytes-ok".to_string())),
            "resume-file-write-bytes-ok",
        );
    }

    fn resume_file_write_bytes_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-write-bytes-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileWriteBytes),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-write-bytes-err",
        );
    }

    fn resume_file_append_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-append-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAppend),
            TaskStep::ResumeOk(ValueRep::String("append-ok".to_string())),
            "resume-file-append-ok",
        );
    }

    fn resume_file_append_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-append-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAppend),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-append-err",
        );
    }

    fn resume_file_append_bytes_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-append-bytes-ok",
        );
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAppendBytes),
            TaskStep::ResumeOk(ValueRep::String("append-bytes-ok".to_string())),
            "resume-file-append-bytes-ok",
        );
    }

    fn resume_file_append_bytes_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-append-bytes-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileAppendBytes),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-append-bytes-err",
        );
    }

    fn resume_file_truncate_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-truncate-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileTruncate),
            TaskStep::ResumeOk(ValueRep::String("truncate-ok".to_string())),
            "resume-file-truncate-ok",
        );
    }

    fn resume_file_truncate_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-truncate-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileTruncate),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-truncate-err",
        );
    }

    fn resume_file_mkdir_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-mkdir-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkdir),
            TaskStep::ResumeOk(ValueRep::String("mkdir-ok".to_string())),
            "resume-file-mkdir-ok",
        );
    }

    fn resume_file_mkdir_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-mkdir-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkdir),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-mkdir-err",
        );
    }

    fn resume_file_mkdirs_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-file-mkdirs-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkdirs),
            TaskStep::ResumeOk(ValueRep::String("mkdirs-ok".to_string())),
            "resume-file-mkdirs-ok",
        );
    }

    fn resume_file_mkdirs_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-mkdirs-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkdirs),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-mkdirs-err",
        );
    }

    fn resume_file_mk_temp_dir_ok(ctx: CtxBorrow<'_>, s: Suspension, path: String) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-mk-temp-dir-ok",
        );
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkTempDir),
            TaskStep::ResumeOk(ValueRep::String(path)),
            "resume-file-mk-temp-dir-ok",
        );
    }

    fn resume_file_mk_temp_dir_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-file-mk-temp-dir-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::FileMkTempDir),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-file-mk-temp-dir-err",
        );
    }

    fn resume_process_exec_ok(ctx: CtxBorrow<'_>, s: Suspension, process_id: u64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-exec-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessExec = rep.req else {
            panic!("resume-process-exec-ok called on non process-exec suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-exec-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-exec-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            scratch.process_id = Some(process_id);
            scratch.stage = ProcessRoundtripStage::Pid;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("proc={process_id}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_exec_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-exec-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessExec),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-exec-err",
        );
    }

    fn resume_process_exit_value_ok(ctx: CtxBorrow<'_>, s: Suspension, code: i32) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-exit-value-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessExitValue = rep.req else {
            panic!("resume-process-exit-value-ok called on non process-exit-value suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-exit-value-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-exit-value-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::ExitValue {
                panic!(
                    "process-roundtrip: exit-value-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            if code != 7 {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(format!(
                    "process-roundtrip: expected exit=7, got exit={code}"
                ))));
                state.ready.push_back(task_id);
                return;
            }
            scratch.stage = ProcessRoundtripStage::IsAliveAfter;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("exit={code}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_exit_value_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-exit-value-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessExitValue),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-exit-value-err",
        );
    }

    fn resume_process_is_alive_ok(ctx: CtxBorrow<'_>, s: Suspension, is_alive: bool) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-is-alive-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessIsAlive = rep.req else {
            panic!("resume-process-is-alive-ok called on non process-is-alive suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-is-alive-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-is-alive-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);

            match scratch.stage {
                ProcessRoundtripStage::IsAliveBefore => {
                    if !is_alive {
                        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                            "process-roundtrip: expected alive=true".to_string(),
                        )));
                        state.ready.push_back(task_id);
                        return;
                    }
                    scratch.stage = ProcessRoundtripStage::WaitTimeout;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                ProcessRoundtripStage::IsAliveAfter => {
                    if is_alive {
                        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                            "process-roundtrip: expected alive=false".to_string(),
                        )));
                        state.ready.push_back(task_id);
                        return;
                    }
                    scratch.stage = ProcessRoundtripStage::Release;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                _ => {
                    panic!(
                        "process-roundtrip: is-alive-ok in unexpected stage {:?}",
                        scratch.stage
                    );
                }
            }
        }

        let out = format!("alive={is_alive}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_is_alive_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-is-alive-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessIsAlive),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-is-alive-err",
        );
    }

    fn resume_process_pid_ok(ctx: CtxBorrow<'_>, s: Suspension, pid: i64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-pid-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessPid = rep.req else {
            panic!("resume-process-pid-ok called on non process-pid suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-pid-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-pid-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::Pid {
                panic!(
                    "process-roundtrip: pid-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            if pid <= 0 {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "process-roundtrip: invalid pid".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }
            scratch.stage = ProcessRoundtripStage::IsAliveBefore;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("pid={pid}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_pid_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-pid-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessPid),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-pid-err",
        );
    }

    fn resume_process_stop_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-stop-ok");
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessStop),
            TaskStep::ResumeOk(ValueRep::String("stopped".to_string())),
            "resume-process-stop-ok",
        );
    }

    fn resume_process_stop_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-process-stop-err");
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessStop),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-stop-err",
        );
    }

    fn resume_process_wait_for_ok(ctx: CtxBorrow<'_>, s: Suspension, code: i32) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-wait-for-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessWaitFor = rep.req else {
            panic!("resume-process-wait-for-ok called on non process-wait-for suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-wait-for-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-wait-for-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::WaitFor {
                panic!(
                    "process-roundtrip: wait-for-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            if code != 7 {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(format!(
                    "process-roundtrip: expected wait=7, got wait={code}"
                ))));
                state.ready.push_back(task_id);
                return;
            }
            scratch.stage = ProcessRoundtripStage::ExitValue;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("wait={code}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_wait_for_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-wait-for-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessWaitFor),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-wait-for-err",
        );
    }

    fn resume_process_wait_for_timeout_ok(ctx: CtxBorrow<'_>, s: Suspension, finished: bool) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-wait-for-timeout-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessWaitForTimeout = rep.req else {
            panic!("resume-process-wait-for-timeout-ok called on non process-wait-for-timeout suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-wait-for-timeout-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-wait-for-timeout-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::WaitTimeout {
                panic!(
                    "process-roundtrip: wait-for-timeout-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            if finished {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "process-roundtrip: expected finished=false".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }
            scratch.stage = ProcessRoundtripStage::StdoutReady;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("finished={finished}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_wait_for_timeout_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-wait-for-timeout-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessWaitForTimeout),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-wait-for-timeout-err",
        );
    }

    fn resume_process_stdin_write_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stdin-write-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessStdinWrite = rep.req else {
            panic!("resume-process-stdin-write-ok called on non process-stdin-write suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-stdin-write-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-stdin-write-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::StdinWrite {
                panic!(
                    "process-roundtrip: stdin-write-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            scratch.stage = ProcessRoundtripStage::StdoutOk;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        task.state =
            TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("stdin-wrote=3".to_string())));
        state.ready.push_back(task_id);
    }

    fn resume_process_stdin_write_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stdin-write-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessStdinWrite),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-stdin-write-err",
        );
    }

    fn resume_process_stdout_read_ok(ctx: CtxBorrow<'_>, s: Suspension, bytes: Vec<u8>) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stdout-read-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessStdoutRead = rep.req else {
            panic!("resume-process-stdout-read-ok called on non process-stdout-read suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-stdout-read-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-stdout-read-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);

            if bytes.is_empty() {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "process-roundtrip: unexpected EOF on stdout".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }

            scratch.stdout.extend_from_slice(&bytes);
            match scratch.stage {
                ProcessRoundtripStage::StdoutReady => {
                    if scratch.stdout.len() < 6 {
                        task.state = TaskState::Ready(TaskStep::Start);
                        state.ready.push_back(task_id);
                        return;
                    }
                    if &scratch.stdout[..6] != b"ready\n" {
                        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                            "process-roundtrip: unexpected stdout (ready)".to_string(),
                        )));
                        state.ready.push_back(task_id);
                        return;
                    }
                    scratch.stdout.clear();
                    scratch.stage = ProcessRoundtripStage::StdinWrite;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                ProcessRoundtripStage::StdoutOk => {
                    if scratch.stdout.len() < 3 {
                        task.state = TaskState::Ready(TaskStep::Start);
                        state.ready.push_back(task_id);
                        return;
                    }
                    if &scratch.stdout[..3] != b"ok\n" {
                        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                            "process-roundtrip: unexpected stdout (ok)".to_string(),
                        )));
                        state.ready.push_back(task_id);
                        return;
                    }
                    scratch.stdout.clear();
                    scratch.stage = ProcessRoundtripStage::StderrErr;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                _ => {
                    panic!(
                        "process-roundtrip: stdout-read-ok in unexpected stage {:?}",
                        scratch.stage
                    );
                }
            }
        }

        let first = bytes.first().copied().unwrap_or(0);
        let out = format!("stdout={} first={first}", bytes.len());
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_stdout_read_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stdout-read-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessStdoutRead),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-stdout-read-err",
        );
    }

    fn resume_process_stderr_read_ok(ctx: CtxBorrow<'_>, s: Suspension, bytes: Vec<u8>) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stderr-read-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessStderrRead = rep.req else {
            panic!("resume-process-stderr-read-ok called on non process-stderr-read suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-stderr-read-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-stderr-read-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::StderrErr {
                panic!(
                    "process-roundtrip: stderr-read-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            if bytes.is_empty() {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "process-roundtrip: unexpected EOF on stderr".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }

            scratch.stderr.extend_from_slice(&bytes);
            if scratch.stderr.len() < 4 {
                task.state = TaskState::Ready(TaskStep::Start);
                state.ready.push_back(task_id);
                return;
            }
            if &scratch.stderr[..4] != b"err\n" {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "process-roundtrip: unexpected stderr".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }

            scratch.stderr.clear();
            scratch.stage = ProcessRoundtripStage::WaitFor;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let first = bytes.first().copied().unwrap_or(0);
        let out = format!("stderr={} first={first}", bytes.len());
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_process_stderr_read_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-stderr-read-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessStderrRead),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-stderr-read-err",
        );
    }

    fn resume_process_release_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-release-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::ProcessRelease = rep.req else {
            panic!("resume-process-release-ok called on non process-release suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-process-release-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-process-release-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 53 {
            let scratch = task
                .proc_roundtrip
                .get_or_insert_with(ProcessRoundtripScratch::new);
            if scratch.stage != ProcessRoundtripStage::Release {
                panic!(
                    "process-roundtrip: release-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            task.proc_roundtrip = None;
            task.state =
                TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("proc-ok".to_string())));
            state.ready.push_back(task_id);
            return;
        }

        task.state =
            TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("released".to_string())));
        state.ready.push_back(task_id);
    }

    fn resume_process_release_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-process-release-err",
        );
        let out = format!("{} {}", err.kind_code, err.msg);
        resume_blocked_task(
            ctx,
            s,
            |req| matches!(req, SuspensionReqRep::ProcessRelease),
            TaskStep::ResumeThrow(ValueRep::String(out)),
            "resume-process-release-err",
        );
    }

    fn resume_tcp_socket_connect_ok(ctx: CtxBorrow<'_>, s: Suspension, socket_id: u64) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-tcp-socket-connect-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketConnect = rep.req else {
            panic!("resume-tcp-socket-connect-ok called on non tcp-socket-connect suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-connect-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-connect-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            scratch.client_socket_id = Some(socket_id);
            scratch.stage = TcpRoundtripStage::Accept;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("socket={socket_id}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_connect_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-tcp-socket-connect-err",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketConnect = rep.req else {
            panic!("resume-tcp-socket-connect-err called on non tcp-socket-connect suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-connect-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-connect-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_read_ok(ctx: CtxBorrow<'_>, s: Suspension, bytes: Vec<u8>) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-read-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketRead = rep.req else {
            panic!("resume-tcp-socket-read-ok called on non tcp-socket-read suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-read-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-read-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);

            if scratch.stage != TcpRoundtripStage::ServerRead {
                panic!("tcp-roundtrip: read-ok in unexpected stage {:?}", scratch.stage);
            }

            if bytes.is_empty() {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(
                    "tcp-roundtrip: unexpected EOF".to_string(),
                )));
                state.ready.push_back(task_id);
                return;
            }

            scratch.recv.extend_from_slice(&bytes);
            if scratch.recv.len() < 4 {
                task.state = TaskState::Ready(TaskStep::Start);
                state.ready.push_back(task_id);
                return;
            }

            if &scratch.recv[..4] != b"ping" {
                task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(format!(
                    "tcp-roundtrip: bad payload: {:?}",
                    &scratch.recv[..4]
                ))));
                state.ready.push_back(task_id);
                return;
            }

            scratch.stage = TcpRoundtripStage::CloseServerSocket;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let first = bytes.first().copied().unwrap_or(0);
        let out = format!("read={} first={first}", bytes.len());
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_read_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-read-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketRead = rep.req else {
            panic!("resume-tcp-socket-read-err called on non tcp-socket-read suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-read-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-read-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_write_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-write-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketWrite = rep.req else {
            panic!("resume-tcp-socket-write-ok called on non tcp-socket-write suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-write-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-write-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            if scratch.stage != TcpRoundtripStage::ClientWrite {
                panic!(
                    "tcp-roundtrip: write-ok in unexpected stage {:?}",
                    scratch.stage
                );
            }
            scratch.stage = TcpRoundtripStage::ServerRead;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("wrote=3".to_string())));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_write_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-write-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketWrite = rep.req else {
            panic!("resume-tcp-socket-write-err called on non tcp-socket-write suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-write-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-write-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_close_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-close-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketClose = rep.req else {
            panic!("resume-tcp-socket-close-ok called on non tcp-socket-close suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-close-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-close-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            match scratch.stage {
                TcpRoundtripStage::CloseServerSocket => {
                    scratch.stage = TcpRoundtripStage::CloseClientSocket;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                TcpRoundtripStage::CloseClientSocket => {
                    scratch.stage = TcpRoundtripStage::CloseServer;
                    task.state = TaskState::Ready(TaskStep::Start);
                    state.ready.push_back(task_id);
                    return;
                }
                _ => {
                    panic!(
                        "tcp-roundtrip: close-ok in unexpected stage {:?}",
                        scratch.stage
                    );
                }
            }
        }

        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("closed".to_string())));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_socket_close_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-socket-close-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpSocketClose = rep.req else {
            panic!("resume-tcp-socket-close-err called on non tcp-socket-close suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-socket-close-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-socket-close-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_bind_ok(ctx: CtxBorrow<'_>, s: Suspension, server_id: u64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-bind-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerBind = rep.req else {
            panic!("resume-tcp-server-bind-ok called on non tcp-server-bind suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-bind-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-bind-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            scratch.server_id = Some(server_id);
            scratch.stage = TcpRoundtripStage::LocalPort;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("server={server_id}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_bind_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-bind-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerBind = rep.req else {
            panic!("resume-tcp-server-bind-err called on non tcp-server-bind suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-bind-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-bind-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_accept_ok(ctx: CtxBorrow<'_>, s: Suspension, socket_id: u64) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-accept-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerAccept = rep.req else {
            panic!("resume-tcp-server-accept-ok called on non tcp-server-accept suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-accept-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-accept-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            scratch.server_socket_id = Some(socket_id);
            scratch.stage = TcpRoundtripStage::ClientWrite;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("socket={socket_id}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_accept_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-accept-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerAccept = rep.req else {
            panic!("resume-tcp-server-accept-err called on non tcp-server-accept suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-accept-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-accept-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_local_port_ok(ctx: CtxBorrow<'_>, s: Suspension, port: u16) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-tcp-server-local-port-ok",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerLocalPort = rep.req else {
            panic!("resume-tcp-server-local-port-ok called on non tcp-server-local-port suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-local-port-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-local-port-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            let scratch = task
                .tcp_roundtrip
                .get_or_insert_with(TcpRoundtripScratch::new);
            scratch.port = Some(port);
            scratch.stage = TcpRoundtripStage::Connect;
            task.state = TaskState::Ready(TaskStep::Start);
            state.ready.push_back(task_id);
            return;
        }

        let out = format!("port={port}");
        task.state = TaskState::Ready(TaskStep::ResumeOk(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_local_port_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(
            LogLevel::Info,
            "flix-smoke-guest: resume-tcp-server-local-port-err",
        );

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerLocalPort = rep.req else {
            panic!("resume-tcp-server-local-port-err called on non tcp-server-local-port suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-local-port-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-local-port-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_close_ok(ctx: CtxBorrow<'_>, s: Suspension) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-close-ok");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerClose = rep.req else {
            panic!("resume-tcp-server-close-ok called on non tcp-server-close suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-close-ok for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-close-ok for task-id={task_id} that is not blocked");
        };

        if task.def_id == 52 {
            task.tcp_roundtrip = None;
            task.state =
                TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("tcp-ok".to_string())));
            state.ready.push_back(task_id);
            return;
        }

        task.state =
            TaskState::Ready(TaskStep::ResumeOk(ValueRep::String("server-closed".to_string())));
        state.ready.push_back(task_id);
    }

    fn resume_tcp_server_close_err(ctx: CtxBorrow<'_>, s: Suspension, err: IoError) {
        log(LogLevel::Info, "flix-smoke-guest: resume-tcp-server-close-err");

        let rep = s.get::<SuspensionRep>();
        let task_id = rep.task_id;
        let SuspensionReqRep::TcpServerClose = rep.req else {
            panic!("resume-tcp-server-close-err called on non tcp-server-close suspension");
        };

        let ctx_rep = ctx.get::<CtxRep>();
        let mut state = ctx_rep.state.borrow_mut();
        let Some(task) = state.tasks.get_mut(&task_id) else {
            panic!("resume-tcp-server-close-err for unknown task-id={task_id}");
        };

        let TaskState::Blocked = task.state else {
            panic!("resume-tcp-server-close-err for task-id={task_id} that is not blocked");
        };

        let out = format!("{} {}", err.kind_code, err.msg);
        task.state = TaskState::Ready(TaskStep::ResumeThrow(ValueRep::String(out)));
        state.ready.push_back(task_id);
    }

    fn box_i32(_ctx: CtxBorrow<'_>, x: i32) -> Value {
        Value::new(ValueRep::I32(x))
    }

    fn unbox_i32(_ctx: CtxBorrow<'_>, v: ValueBorrow<'_>) -> i32 {
        match v.get::<ValueRep>() {
            ValueRep::I32(x) => *x,
            _ => 0,
        }
    }

    fn box_bool(_ctx: CtxBorrow<'_>, b: bool) -> Value {
        Value::new(ValueRep::Bool(b))
    }

    fn unbox_bool(_ctx: CtxBorrow<'_>, v: ValueBorrow<'_>) -> bool {
        match v.get::<ValueRep>() {
            ValueRep::Bool(b) => *b,
            _ => false,
        }
    }

    fn box_string(_ctx: CtxBorrow<'_>, s: String) -> Value {
        Value::new(ValueRep::String(s))
    }

    fn unbox_string(_ctx: CtxBorrow<'_>, v: ValueBorrow<'_>) -> String {
        match v.get::<ValueRep>() {
            ValueRep::String(s) => s.clone(),
            _ => String::new(),
        }
    }
}

impl GuestCtx for CtxRep {}
impl GuestValue for ValueRep {}
impl GuestSuspension for SuspensionRep {}
