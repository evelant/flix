use anyhow::{Context, Result};
use std::thread;
use std::time::Duration;
use wasmtime::Store;

use crate::bindings::exports::flix::runtime::runtime::{Guest, IoError, OpRequest, Suspension};

pub trait OpHandler<T> {
    fn handle_op(
        &mut self,
        store: &mut Store<T>,
        rt: &Guest,
        ctx: crate::bindings::exports::flix::runtime::runtime::Ctx,
        suspension: Suspension,
        req: OpRequest,
    ) -> Result<()>;
}

pub struct FlixRunner {
    pub budget: u32,
}

impl Default for FlixRunner {
    fn default() -> Self {
        Self { budget: 100 }
    }
}

impl FlixRunner {
    pub fn run_task_to_completion<T, H>(
        &self,
        store: &mut Store<T>,
        rt: &Guest,
        ctx: crate::bindings::exports::flix::runtime::runtime::Ctx,
        task_id: u64,
        handler: &mut H,
    ) -> Result<crate::bindings::exports::flix::runtime::runtime::TaskOutcome>
    where
        H: OpHandler<T>,
    {
        loop {
            if let Some(outcome) = rt
                .call_poll_task(&mut *store, ctx, task_id)
                .context("poll-task failed")?
            {
                return Ok(outcome);
            }

            let suspensions = rt
                .call_sched_step(&mut *store, ctx, self.budget)
                .context("sched-step failed")?;

            if suspensions.is_empty() {
                thread::yield_now();
                continue;
            }

            for s in suspensions {
                let req = rt
                    .call_suspension_request(&mut *store, ctx, s)
                    .context("suspension-request failed")?;

                if let Err(e) = self.handle_one(&mut *store, rt, ctx, s, req, handler) {
                    // Best-effort: resume with an `Other` IO error if possible.
                    let msg = e.to_string();
                    let err = IoError {
                        kind_code: 14,
                        msg,
                    };

                    let req2 = rt
                        .call_suspension_request(&mut *store, ctx, s)
                        .context("suspension-request failed (error fallback)")?;

                    if let Err(e2) = resume_io_err(&mut *store, rt, ctx, s, req2, &err) {
                        return Err(e2).context(e);
                    }
                }
            }
        }
    }

    fn handle_one<T, H>(
        &self,
        store: &mut Store<T>,
        rt: &Guest,
        ctx: crate::bindings::exports::flix::runtime::runtime::Ctx,
        suspension: Suspension,
        req: OpRequest,
        handler: &mut H,
    ) -> Result<()>
    where
        H: OpHandler<T>,
    {
        match req {
            OpRequest::TimerSleep(r) => {
                thread::sleep(Duration::from_millis(r.ms));
                rt.call_resume_timer_sleep(store, ctx, suspension)?;
                Ok(())
            }
            other => handler.handle_op(store, rt, ctx, suspension, other),
        }
    }
}

pub fn resume_io_err<T>(
    store: &mut Store<T>,
    rt: &Guest,
    ctx: crate::bindings::exports::flix::runtime::runtime::Ctx,
    suspension: Suspension,
    req: OpRequest,
    err: &IoError,
) -> Result<()> {
    match req {
        OpRequest::HttpRequest(_) => rt.call_resume_http_err(store, ctx, suspension, err)?,

        OpRequest::FileExists(_) => rt.call_resume_file_exists_err(store, ctx, suspension, err)?,
        OpRequest::FileIsDirectory(_) => rt.call_resume_file_is_directory_err(store, ctx, suspension, err)?,
        OpRequest::FileIsRegularFile(_) => rt.call_resume_file_is_regular_file_err(store, ctx, suspension, err)?,
        OpRequest::FileIsReadable(_) => rt.call_resume_file_is_readable_err(store, ctx, suspension, err)?,
        OpRequest::FileIsSymbolicLink(_) => rt.call_resume_file_is_symbolic_link_err(store, ctx, suspension, err)?,
        OpRequest::FileIsWritable(_) => rt.call_resume_file_is_writable_err(store, ctx, suspension, err)?,
        OpRequest::FileIsExecutable(_) => rt.call_resume_file_is_executable_err(store, ctx, suspension, err)?,

        OpRequest::FileAccessTime(_) => rt.call_resume_file_access_time_err(store, ctx, suspension, err)?,
        OpRequest::FileCreationTime(_) => rt.call_resume_file_creation_time_err(store, ctx, suspension, err)?,
        OpRequest::FileModificationTime(_) => rt.call_resume_file_modification_time_err(store, ctx, suspension, err)?,
        OpRequest::FileSize(_) => rt.call_resume_file_size_err(store, ctx, suspension, err)?,

        OpRequest::FileRead(_) => rt.call_resume_file_read_err(store, ctx, suspension, err)?,
        OpRequest::FileReadLines(_) => rt.call_resume_file_read_lines_err(store, ctx, suspension, err)?,
        OpRequest::FileReadBytes(_) => rt.call_resume_file_read_bytes_err(store, ctx, suspension, err)?,
        OpRequest::FileList(_) => rt.call_resume_file_list_err(store, ctx, suspension, err)?,

        OpRequest::FileWrite(_) => rt.call_resume_file_write_err(store, ctx, suspension, err)?,
        OpRequest::FileWriteBytes(_) => rt.call_resume_file_write_bytes_err(store, ctx, suspension, err)?,
        OpRequest::FileAppend(_) => rt.call_resume_file_append_err(store, ctx, suspension, err)?,
        OpRequest::FileAppendBytes(_) => rt.call_resume_file_append_bytes_err(store, ctx, suspension, err)?,
        OpRequest::FileTruncate(_) => rt.call_resume_file_truncate_err(store, ctx, suspension, err)?,
        OpRequest::FileMkdir(_) => rt.call_resume_file_mkdir_err(store, ctx, suspension, err)?,
        OpRequest::FileMkdirs(_) => rt.call_resume_file_mkdirs_err(store, ctx, suspension, err)?,
        OpRequest::FileMkTempDir(_) => rt.call_resume_file_mk_temp_dir_err(store, ctx, suspension, err)?,

        OpRequest::ProcessExec(_) => rt.call_resume_process_exec_err(store, ctx, suspension, err)?,
        OpRequest::ProcessExitValue(_) => rt.call_resume_process_exit_value_err(store, ctx, suspension, err)?,
        OpRequest::ProcessIsAlive(_) => rt.call_resume_process_is_alive_err(store, ctx, suspension, err)?,
        OpRequest::ProcessPid(_) => rt.call_resume_process_pid_err(store, ctx, suspension, err)?,
        OpRequest::ProcessStop(_) => rt.call_resume_process_stop_err(store, ctx, suspension, err)?,
        OpRequest::ProcessWaitFor(_) => rt.call_resume_process_wait_for_err(store, ctx, suspension, err)?,
        OpRequest::ProcessWaitForTimeout(_) => {
            rt.call_resume_process_wait_for_timeout_err(store, ctx, suspension, err)?
        }
        OpRequest::ProcessStdinWrite(_) => rt.call_resume_process_stdin_write_err(store, ctx, suspension, err)?,
        OpRequest::ProcessStdoutRead(_) => rt.call_resume_process_stdout_read_err(store, ctx, suspension, err)?,
        OpRequest::ProcessStderrRead(_) => rt.call_resume_process_stderr_read_err(store, ctx, suspension, err)?,
        OpRequest::ProcessRelease(_) => rt.call_resume_process_release_err(store, ctx, suspension, err)?,

        OpRequest::TcpSocketConnect(_) => rt.call_resume_tcp_socket_connect_err(store, ctx, suspension, err)?,
        OpRequest::TcpSocketRead(_) => rt.call_resume_tcp_socket_read_err(store, ctx, suspension, err)?,
        OpRequest::TcpSocketWrite(_) => rt.call_resume_tcp_socket_write_err(store, ctx, suspension, err)?,
        OpRequest::TcpSocketClose(_) => rt.call_resume_tcp_socket_close_err(store, ctx, suspension, err)?,
        OpRequest::TcpServerBind(_) => rt.call_resume_tcp_server_bind_err(store, ctx, suspension, err)?,
        OpRequest::TcpServerAccept(_) => rt.call_resume_tcp_server_accept_err(store, ctx, suspension, err)?,
        OpRequest::TcpServerLocalPort(_) => rt.call_resume_tcp_server_local_port_err(store, ctx, suspension, err)?,
        OpRequest::TcpServerClose(_) => rt.call_resume_tcp_server_close_err(store, ctx, suspension, err)?,

        OpRequest::Unknown(_) | OpRequest::TimerSleep(_) => {
            // No typed IoError resumer. Leave it un-resumed and let the error surface.
            anyhow::bail!("cannot resume IoError for request kind")
        }
    }

    Ok(())
}
