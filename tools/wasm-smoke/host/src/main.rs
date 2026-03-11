use anyhow::{anyhow, Context, Result};
use std::time::{SystemTime, UNIX_EPOCH};
use wasmtime::{
    Config, Engine, Store,
    component::{Component, HasSelf, Linker},
};

mod bindings {
    wasmtime::component::bindgen!({
        path: "../../../runtime/wit/flix-bindings",
        world: "flix",
    });
}

use bindings::flix::sys::sys::{Capability, Host as SysHost, LogLevel};
use bindings::exports::flix::runtime::runtime::{
    Exec, HttpHeader, HttpResponse, IoError, OpRequest, TaskOutcome,
};

#[derive(Default)]
struct State;

impl SysHost for State {
    fn log(&mut self, level: LogLevel, msg: String) {
        eprintln!("[guest:{level:?}] {msg}");
    }

    fn time_now_ms(&mut self) -> i64 {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        now.as_millis() as i64
    }

    fn random_bytes(&mut self, len: u32) -> Vec<u8> {
        // Deterministic (but non-cryptographic) bytes for the smoke harness.
        // Real implementations should use OS RNG.
        (0..len).map(|i| (i as u8).wrapping_mul(31)).collect()
    }

    fn has_capability(&mut self, cap: Capability) -> bool {
        matches!(
            cap,
            Capability::Filesystem | Capability::Http | Capability::Sockets | Capability::Threads
        )
    }
}

fn main() -> Result<()> {
    let component_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "../out/flix-smoke.component.wasm".to_string());

    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;

    let component = Component::from_file(&engine, &component_path)
        .with_context(|| format!("failed to load component: {component_path}"))?;

    let mut linker = Linker::<State>::new(&engine);
    bindings::flix::sys::sys::add_to_linker::<_, HasSelf<_>>(&mut linker, |s| s)?;

    let mut store = Store::new(&engine, State::default());

    let flix = bindings::Flix::instantiate(&mut store, &component, &linker)?;
    let rt = flix.flix_runtime_runtime();

    let ctx = rt.call_new_ctx(&mut store)?;

    // --- def 1: add two i32s ---
    let a = rt.call_box_i32(&mut store, ctx, 20)?;
    let b = rt.call_box_i32(&mut store, ctx, 22)?;

    let exec = rt.call_invoke(&mut store, ctx, 1, &[a, b])?;
    let result_value = match exec {
        Exec::Ok(v) => v,
        Exec::Thrown(_) => {
            return Err(anyhow!("guest returned thrown for add"));
        }
        Exec::Suspended(_) => {
            return Err(anyhow!("guest unexpectedly suspended"));
        }
    };

    let sum = rt.call_unbox_i32(&mut store, ctx, result_value)?;
    if sum != 42 {
        return Err(anyhow!("expected 42, got {sum}"));
    }

    a.resource_drop(&mut store)?;
    b.resource_drop(&mut store)?;
    result_value.resource_drop(&mut store)?;

    // --- def 2: invoke can suspend and yields a pollable task-id ---
    let exec = rt.call_invoke(&mut store, ctx, 2, &[])?;
    let (task_id, suspension) = match exec {
        Exec::Suspended(se) => (se.task, se.suspension),
        Exec::Ok(_) => return Err(anyhow!("expected suspended for def-id=2, got ok")),
        Exec::Thrown(_) => return Err(anyhow!("expected suspended for def-id=2, got thrown")),
    };

    let info = rt.call_suspension_peek(&mut store, ctx, suspension)?;
    if info.eff_id != 10 || info.op_id != 20 {
        return Err(anyhow!(
            "unexpected suspension-info: eff-id={} op-id={}",
            info.eff_id,
            info.op_id
        ));
    }

    if rt.call_poll_task(&mut store, ctx, task_id)?.is_some() {
        return Err(anyhow!("expected invoke(def=2) task incomplete before resumption"));
    }

    let resume_in = rt.call_box_string(&mut store, ctx, "resumed via invoke")?;
    rt.call_resume_ok(&mut store, ctx, suspension, resume_in)?;
    resume_in.resource_drop(&mut store)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after invoke-resume, got {}",
            more.len()
        ));
    }

    let outcome = rt
        .call_poll_task(&mut store, ctx, task_id)?
        .ok_or_else(|| anyhow!("expected invoke(def=2) task complete after resumption"))?;
    let v = match outcome {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("invoke(def=2) task unexpectedly threw")),
    };

    let resumed = rt.call_unbox_string(&mut store, ctx, v)?;
    if resumed != "resumed via invoke" {
        return Err(anyhow!(
            "expected 'resumed via invoke', got '{resumed}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 4: typed per-op WIT (timer-sleep) ---
    let t4 = rt.call_start_task(&mut store, ctx, 4, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t4, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TimerSleep(r) => {
            if r.ms != 5 {
                return Err(anyhow!("expected timer-sleep ms=5, got {}", r.ms));
            }
        }
        _ => return Err(anyhow!("expected timer-sleep request")),
    }

    rt.call_resume_timer_sleep(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-timer-sleep, got {}",
            more.len()
        ));
    }

    let out4 = rt
        .call_poll_task(&mut store, ctx, t4)?
        .ok_or_else(|| anyhow!("expected task t4 to be complete after resume-timer-sleep"))?;
    let v = match out4 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t4 unexpectedly threw")),
    };
    let x = rt.call_unbox_i32(&mut store, ctx, v)?;
    if x != 123 {
        return Err(anyhow!("expected 123 from task t4, got {x}"));
    }
    v.resource_drop(&mut store)?;

    // --- def 5: typed per-op WIT (http-request ok/err) ---
    let t5 = rt.call_start_task(&mut store, ctx, 5, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t5, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::HttpRequest(r) => {
            if r.method != "GET" || r.url != "https://example.com/hello" {
                return Err(anyhow!(
                    "unexpected http-request: method={} url={}",
                    r.method,
                    r.url
                ));
            }
            if r.body.is_some() {
                return Err(anyhow!("expected http-request body=None"));
            }
            if r.headers.len() != 1 || r.headers[0].name != "x-req" || r.headers[0].value != "abc"
            {
                return Err(anyhow!("unexpected http-request headers"));
            }
        }
        _ => return Err(anyhow!("expected http-request")),
    }

    rt.call_resume_http_ok(
        &mut store,
        ctx,
        suspensions[0],
        &HttpResponse {
            status: 200,
            headers: vec![HttpHeader {
                name: "x-foo".to_string(),
                value: "bar".to_string(),
            }],
            body: "hello".to_string(),
        },
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-http-ok, got {}",
            more.len()
        ));
    }

    let out5 = rt
        .call_poll_task(&mut store, ctx, t5)?
        .ok_or_else(|| anyhow!("expected task t5 to be complete after resume-http-ok"))?;
    let v = match out5 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t5 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "200 hello" {
        return Err(anyhow!("expected '200 hello' from task t5, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // http-request err
    let t6 = rt.call_start_task(&mut store, ctx, 6, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t6, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::HttpRequest(_)) {
        return Err(anyhow!("expected http-request for task t6"));
    }

    rt.call_resume_http_err(
        &mut store,
        ctx,
        suspensions[0],
        &IoError {
            kind_code: 10, // Timeout
            msg: "timeout".to_string(),
        },
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-http-err, got {}",
            more.len()
        ));
    }

    let out6 = rt
        .call_poll_task(&mut store, ctx, t6)?
        .ok_or_else(|| anyhow!("expected task t6 to be complete after resume-http-err"))?;
    let v = match out6 {
        TaskOutcome::Thrown(v) => v,
        TaskOutcome::Ok(_) => return Err(anyhow!("expected thrown from task t6, got ok")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "10 timeout" {
        return Err(anyhow!("expected '10 timeout' from task t6, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 7: typed per-op WIT (tcp-socket-connect ok/err) ---
    let t7 = rt.call_start_task(&mut store, ctx, 7, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t7, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpSocketConnect(r) => {
            if r.ip != vec![127, 0, 0, 1] || r.port != 8080 {
                return Err(anyhow!(
                    "unexpected tcp-socket-connect request: ip={:?} port={}",
                    r.ip,
                    r.port
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-socket-connect")),
    }

    rt.call_resume_tcp_socket_connect_ok(&mut store, ctx, suspensions[0], 99)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-socket-connect-ok, got {}",
            more.len()
        ));
    }

    let out7 = rt
        .call_poll_task(&mut store, ctx, t7)?
        .ok_or_else(|| anyhow!("expected task t7 to be complete after resume-tcp-socket-connect-ok"))?;
    let v = match out7 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t7 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "socket=99" {
        return Err(anyhow!("expected 'socket=99' from task t7, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // tcp-socket-connect err
    let t8 = rt.call_start_task(&mut store, ctx, 8, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t8, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::TcpSocketConnect(_)) {
        return Err(anyhow!("expected tcp-socket-connect for task t8"));
    }

    rt.call_resume_tcp_socket_connect_err(
        &mut store,
        ctx,
        suspensions[0],
        &IoError {
            kind_code: 42,
            msg: "nope".to_string(),
        },
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-socket-connect-err, got {}",
            more.len()
        ));
    }

    let out8 = rt
        .call_poll_task(&mut store, ctx, t8)?
        .ok_or_else(|| anyhow!("expected task t8 to be complete after resume-tcp-socket-connect-err"))?;
    let v = match out8 {
        TaskOutcome::Thrown(v) => v,
        TaskOutcome::Ok(_) => return Err(anyhow!("expected thrown from task t8, got ok")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "42 nope" {
        return Err(anyhow!("expected '42 nope' from task t8, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 9: typed per-op WIT (tcp-socket-read) ---
    let t9 = rt.call_start_task(&mut store, ctx, 9, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t9, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpSocketRead(r) => {
            if r.socket_id != 99 || r.max_bytes != 4 {
                return Err(anyhow!(
                    "unexpected tcp-socket-read request: socket-id={} max-bytes={}",
                    r.socket_id,
                    r.max_bytes
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-socket-read")),
    }

    rt.call_resume_tcp_socket_read_ok(&mut store, ctx, suspensions[0], &[1u8, 2, 3])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-socket-read-ok, got {}",
            more.len()
        ));
    }

    let out9 = rt
        .call_poll_task(&mut store, ctx, t9)?
        .ok_or_else(|| anyhow!("expected task t9 to be complete after resume-tcp-socket-read-ok"))?;
    let v = match out9 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t9 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "read=3 first=1" {
        return Err(anyhow!("expected 'read=3 first=1' from task t9, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 10: typed per-op WIT (tcp-socket-write) ---
    let t10 = rt.call_start_task(&mut store, ctx, 10, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t10, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpSocketWrite(r) => {
            if r.socket_id != 99 || r.bytes != vec![7, 8, 9] {
                return Err(anyhow!("unexpected tcp-socket-write request"));
            }
        }
        _ => return Err(anyhow!("expected tcp-socket-write")),
    }

    rt.call_resume_tcp_socket_write_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-socket-write-ok, got {}",
            more.len()
        ));
    }

    let out10 = rt
        .call_poll_task(&mut store, ctx, t10)?
        .ok_or_else(|| anyhow!("expected task t10 to be complete after resume-tcp-socket-write-ok"))?;
    let v = match out10 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t10 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "wrote=3" {
        return Err(anyhow!("expected 'wrote=3' from task t10, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 11: typed per-op WIT (tcp-socket-close) ---
    let t11 = rt.call_start_task(&mut store, ctx, 11, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t11, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpSocketClose(r) => {
            if r.socket_id != 99 {
                return Err(anyhow!(
                    "unexpected tcp-socket-close request: socket-id={}",
                    r.socket_id
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-socket-close")),
    }

    rt.call_resume_tcp_socket_close_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-socket-close-ok, got {}",
            more.len()
        ));
    }

    let out11 = rt
        .call_poll_task(&mut store, ctx, t11)?
        .ok_or_else(|| anyhow!("expected task t11 to be complete after resume-tcp-socket-close-ok"))?;
    let v = match out11 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t11 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "closed" {
        return Err(anyhow!("expected 'closed' from task t11, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 12: typed per-op WIT (tcp-server-bind) ---
    let t12 = rt.call_start_task(&mut store, ctx, 12, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t12, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpServerBind(r) => {
            if r.ip != vec![127, 0, 0, 1] || r.port != 8080 {
                return Err(anyhow!(
                    "unexpected tcp-server-bind request: ip={:?} port={}",
                    r.ip,
                    r.port
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-server-bind")),
    }

    rt.call_resume_tcp_server_bind_ok(&mut store, ctx, suspensions[0], 55)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-server-bind-ok, got {}",
            more.len()
        ));
    }

    let out12 = rt
        .call_poll_task(&mut store, ctx, t12)?
        .ok_or_else(|| anyhow!("expected task t12 to be complete after resume-tcp-server-bind-ok"))?;
    let v = match out12 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t12 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "server=55" {
        return Err(anyhow!("expected 'server=55' from task t12, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 13: typed per-op WIT (tcp-server-accept) ---
    let t13 = rt.call_start_task(&mut store, ctx, 13, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t13, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpServerAccept(r) => {
            if r.server_id != 55 {
                return Err(anyhow!(
                    "unexpected tcp-server-accept request: server-id={}",
                    r.server_id
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-server-accept")),
    }

    rt.call_resume_tcp_server_accept_ok(&mut store, ctx, suspensions[0], 77)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-server-accept-ok, got {}",
            more.len()
        ));
    }

    let out13 = rt
        .call_poll_task(&mut store, ctx, t13)?
        .ok_or_else(|| anyhow!("expected task t13 to be complete after resume-tcp-server-accept-ok"))?;
    let v = match out13 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t13 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "socket=77" {
        return Err(anyhow!("expected 'socket=77' from task t13, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 14: typed per-op WIT (tcp-server-local-port) ---
    let t14 = rt.call_start_task(&mut store, ctx, 14, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t14, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpServerLocalPort(r) => {
            if r.server_id != 55 {
                return Err(anyhow!(
                    "unexpected tcp-server-local-port request: server-id={}",
                    r.server_id
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-server-local-port")),
    }

    rt.call_resume_tcp_server_local_port_ok(&mut store, ctx, suspensions[0], 1234)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-server-local-port-ok, got {}",
            more.len()
        ));
    }

    let out14 = rt
        .call_poll_task(&mut store, ctx, t14)?
        .ok_or_else(|| anyhow!("expected task t14 to be complete after resume-tcp-server-local-port-ok"))?;
    let v = match out14 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t14 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "port=1234" {
        return Err(anyhow!("expected 'port=1234' from task t14, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 15: typed per-op WIT (tcp-server-close) ---
    let t15 = rt.call_start_task(&mut store, ctx, 15, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t15, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::TcpServerClose(r) => {
            if r.server_id != 55 {
                return Err(anyhow!(
                    "unexpected tcp-server-close request: server-id={}",
                    r.server_id
                ));
            }
        }
        _ => return Err(anyhow!("expected tcp-server-close")),
    }

    rt.call_resume_tcp_server_close_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-tcp-server-close-ok, got {}",
            more.len()
        ));
    }

    let out15 = rt
        .call_poll_task(&mut store, ctx, t15)?
        .ok_or_else(|| anyhow!("expected task t15 to be complete after resume-tcp-server-close-ok"))?;
    let v = match out15 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t15 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "server-closed" {
        return Err(anyhow!(
            "expected 'server-closed' from task t15, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 16: typed per-op WIT (file-exists) ---
    let t16 = rt.call_start_task(&mut store, ctx, 16, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t16, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileExists(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!("unexpected file-exists request: path={}", r.path));
            }
        }
        _ => return Err(anyhow!("expected file-exists")),
    }

    rt.call_resume_file_exists_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-exists-ok, got {}",
            more.len()
        ));
    }

    let out16 = rt
        .call_poll_task(&mut store, ctx, t16)?
        .ok_or_else(|| anyhow!("expected task t16 to be complete after resume-file-exists-ok"))?;
    let v = match out16 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t16 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "exists=true" {
        return Err(anyhow!("expected 'exists=true' from task t16, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 17: typed per-op WIT (file-size) ---
    let t17 = rt.call_start_task(&mut store, ctx, 17, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t17, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileSize(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!("unexpected file-size request: path={}", r.path));
            }
        }
        _ => return Err(anyhow!("expected file-size")),
    }

    rt.call_resume_file_size_ok(&mut store, ctx, suspensions[0], 1234)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-size-ok, got {}",
            more.len()
        ));
    }

    let out17 = rt
        .call_poll_task(&mut store, ctx, t17)?
        .ok_or_else(|| anyhow!("expected task t17 to be complete after resume-file-size-ok"))?;
    let v = match out17 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t17 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "size=1234" {
        return Err(anyhow!("expected 'size=1234' from task t17, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 18: typed per-op WIT (file-read) ---
    let t18 = rt.call_start_task(&mut store, ctx, 18, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t18, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileRead(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!("unexpected file-read request: path={}", r.path));
            }
        }
        _ => return Err(anyhow!("expected file-read")),
    }

    rt.call_resume_file_read_ok(&mut store, ctx, suspensions[0], "hello")?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-read-ok, got {}",
            more.len()
        ));
    }

    let out18 = rt
        .call_poll_task(&mut store, ctx, t18)?
        .ok_or_else(|| anyhow!("expected task t18 to be complete after resume-file-read-ok"))?;
    let v = match out18 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t18 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "read=hello" {
        return Err(anyhow!("expected 'read=hello' from task t18, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 19: typed per-op WIT (file-read-lines) ---
    let t19 = rt.call_start_task(&mut store, ctx, 19, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t19, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileReadLines(r) => {
            if r.path != "fixtures/lines.txt" {
                return Err(anyhow!(
                    "unexpected file-read-lines request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-read-lines")),
    }

    rt.call_resume_file_read_lines_ok(
        &mut store,
        ctx,
        suspensions[0],
        &["a".to_string(), "b".to_string()],
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-read-lines-ok, got {}",
            more.len()
        ));
    }

    let out19 = rt
        .call_poll_task(&mut store, ctx, t19)?
        .ok_or_else(|| anyhow!("expected task t19 to be complete after resume-file-read-lines-ok"))?;
    let v = match out19 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t19 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "lines=2 first=a" {
        return Err(anyhow!(
            "expected 'lines=2 first=a' from task t19, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 20: typed per-op WIT (file-read-bytes) ---
    let t20 = rt.call_start_task(&mut store, ctx, 20, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t20, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileReadBytes(r) => {
            if r.path != "fixtures/bytes.bin" {
                return Err(anyhow!(
                    "unexpected file-read-bytes request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-read-bytes")),
    }

    rt.call_resume_file_read_bytes_ok(&mut store, ctx, suspensions[0], &[1u8, 2, 3])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-read-bytes-ok, got {}",
            more.len()
        ));
    }

    let out20 = rt
        .call_poll_task(&mut store, ctx, t20)?
        .ok_or_else(|| anyhow!("expected task t20 to be complete after resume-file-read-bytes-ok"))?;
    let v = match out20 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t20 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "bytes=3 first=1" {
        return Err(anyhow!(
            "expected 'bytes=3 first=1' from task t20, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 21: typed per-op WIT (file-list) ---
    let t21 = rt.call_start_task(&mut store, ctx, 21, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t21, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileList(r) => {
            if r.path != "fixtures" {
                return Err(anyhow!("unexpected file-list request: path={}", r.path));
            }
        }
        _ => return Err(anyhow!("expected file-list")),
    }

    rt.call_resume_file_list_ok(
        &mut store,
        ctx,
        suspensions[0],
        &["x".to_string(), "y".to_string()],
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-list-ok, got {}",
            more.len()
        ));
    }

    let out21 = rt
        .call_poll_task(&mut store, ctx, t21)?
        .ok_or_else(|| anyhow!("expected task t21 to be complete after resume-file-list-ok"))?;
    let v = match out21 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t21 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "list=2 first=x" {
        return Err(anyhow!(
            "expected 'list=2 first=x' from task t21, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 22: typed per-op WIT (file-write) ---
    let t22 = rt.call_start_task(&mut store, ctx, 22, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t22, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileWrite(r) => {
            if r.path != "out/write.txt" || r.data != "hello" {
                return Err(anyhow!(
                    "unexpected file-write request: path={} data={}",
                    r.path,
                    r.data
                ));
            }
        }
        _ => return Err(anyhow!("expected file-write")),
    }

    rt.call_resume_file_write_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-write-ok, got {}",
            more.len()
        ));
    }

    let out22 = rt
        .call_poll_task(&mut store, ctx, t22)?
        .ok_or_else(|| anyhow!("expected task t22 to be complete after resume-file-write-ok"))?;
    let v = match out22 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t22 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "write-ok" {
        return Err(anyhow!("expected 'write-ok' from task t22, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 23: typed per-op WIT (file-write-bytes err) ---
    let t23 = rt.call_start_task(&mut store, ctx, 23, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t23, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileWriteBytes(r) => {
            if r.path != "out/write.bin" {
                return Err(anyhow!(
                    "unexpected file-write-bytes request: path={}",
                    r.path
                ));
            }
            if r.bytes != vec![1, 2, 3] {
                return Err(anyhow!("unexpected file-write-bytes bytes"));
            }
        }
        _ => return Err(anyhow!("expected file-write-bytes")),
    }

    rt.call_resume_file_write_bytes_err(
        &mut store,
        ctx,
        suspensions[0],
        &IoError {
            kind_code: 42,
            msg: "nope".to_string(),
        },
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-write-bytes-err, got {}",
            more.len()
        ));
    }

    let out23 = rt
        .call_poll_task(&mut store, ctx, t23)?
        .ok_or_else(|| anyhow!("expected task t23 to be complete after resume-file-write-bytes-err"))?;
    let v = match out23 {
        TaskOutcome::Thrown(v) => v,
        TaskOutcome::Ok(_) => return Err(anyhow!("task t23 unexpectedly returned ok")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "42 nope" {
        return Err(anyhow!("expected '42 nope' from task t23, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 24: typed per-op WIT (file-mk-temp-dir) ---
    let t24 = rt.call_start_task(&mut store, ctx, 24, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t24, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileMkTempDir(r) => {
            if r.prefix != "flix" {
                return Err(anyhow!(
                    "unexpected file-mk-temp-dir request: prefix={}",
                    r.prefix
                ));
            }
        }
        _ => return Err(anyhow!("expected file-mk-temp-dir")),
    }

    rt.call_resume_file_mk_temp_dir_ok(&mut store, ctx, suspensions[0], "tmp/flix-123")?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-mk-temp-dir-ok, got {}",
            more.len()
        ));
    }

    let out24 = rt
        .call_poll_task(&mut store, ctx, t24)?
        .ok_or_else(|| anyhow!("expected task t24 to be complete after resume-file-mk-temp-dir-ok"))?;
    let v = match out24 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t24 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "tmp/flix-123" {
        return Err(anyhow!(
            "expected 'tmp/flix-123' from task t24, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 25: typed per-op WIT (process-exec ok) ---
    let t25 = rt.call_start_task(&mut store, ctx, 25, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t25, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessExec(r) => {
            if r.argv != vec!["echo".to_string(), "hello".to_string()] {
                return Err(anyhow!("unexpected process-exec argv"));
            }
            if r.cwd.as_deref() != Some("tmp") {
                return Err(anyhow!("unexpected process-exec cwd"));
            }
            if r.env.len() != 1 || r.env[0].key != "FOO" || r.env[0].value != "BAR" {
                return Err(anyhow!("unexpected process-exec env"));
            }
        }
        _ => return Err(anyhow!("expected process-exec")),
    }

    rt.call_resume_process_exec_ok(&mut store, ctx, suspensions[0], 99)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-exec-ok, got {}",
            more.len()
        ));
    }

    let out25 = rt
        .call_poll_task(&mut store, ctx, t25)?
        .ok_or_else(|| anyhow!("expected task t25 to be complete after resume-process-exec-ok"))?;
    let v = match out25 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t25 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "proc=99" {
        return Err(anyhow!("expected 'proc=99' from task t25, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 26: typed per-op WIT (process-exec err) ---
    let t26 = rt.call_start_task(&mut store, ctx, 26, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t26, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::ProcessExec(_)) {
        return Err(anyhow!("expected process-exec for task t26"));
    }

    rt.call_resume_process_exec_err(
        &mut store,
        ctx,
        suspensions[0],
        &IoError {
            kind_code: 42,
            msg: "nope".to_string(),
        },
    )?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-exec-err, got {}",
            more.len()
        ));
    }

    let out26 = rt
        .call_poll_task(&mut store, ctx, t26)?
        .ok_or_else(|| anyhow!("expected task t26 to be complete after resume-process-exec-err"))?;
    let v = match out26 {
        TaskOutcome::Thrown(v) => v,
        TaskOutcome::Ok(_) => return Err(anyhow!("expected thrown from task t26, got ok")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "42 nope" {
        return Err(anyhow!("expected '42 nope' from task t26, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 27: typed per-op WIT (process-pid) ---
    let t27 = rt.call_start_task(&mut store, ctx, 27, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t27, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessPid(r) => {
            if r.process_id != 77 {
                return Err(anyhow!("unexpected process-pid request: process-id={}", r.process_id));
            }
        }
        _ => return Err(anyhow!("expected process-pid")),
    }

    rt.call_resume_process_pid_ok(&mut store, ctx, suspensions[0], 1234)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-pid-ok, got {}",
            more.len()
        ));
    }

    let out27 = rt
        .call_poll_task(&mut store, ctx, t27)?
        .ok_or_else(|| anyhow!("expected task t27 to be complete after resume-process-pid-ok"))?;
    let v = match out27 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t27 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "pid=1234" {
        return Err(anyhow!("expected 'pid=1234' from task t27, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 28: typed per-op WIT (process-wait-for) ---
    let t28 = rt.call_start_task(&mut store, ctx, 28, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t28, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessWaitFor(r) => {
            if r.process_id != 77 {
                return Err(anyhow!(
                    "unexpected process-wait-for request: process-id={}",
                    r.process_id
                ));
            }
        }
        _ => return Err(anyhow!("expected process-wait-for")),
    }

    rt.call_resume_process_wait_for_ok(&mut store, ctx, suspensions[0], 0)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-wait-for-ok, got {}",
            more.len()
        ));
    }

    let out28 = rt
        .call_poll_task(&mut store, ctx, t28)?
        .ok_or_else(|| anyhow!("expected task t28 to be complete after resume-process-wait-for-ok"))?;
    let v = match out28 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t28 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "wait=0" {
        return Err(anyhow!("expected 'wait=0' from task t28, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 29: typed per-op WIT (process-wait-for-timeout) ---
    let t29 = rt.call_start_task(&mut store, ctx, 29, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t29, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessWaitForTimeout(r) => {
            if r.process_id != 77 || r.timeout_ms != 1000 {
                return Err(anyhow!(
                    "unexpected process-wait-for-timeout request: process-id={} timeout-ms={}",
                    r.process_id,
                    r.timeout_ms
                ));
            }
        }
        _ => return Err(anyhow!("expected process-wait-for-timeout")),
    }

    rt.call_resume_process_wait_for_timeout_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-wait-for-timeout-ok, got {}",
            more.len()
        ));
    }

    let out29 = rt
        .call_poll_task(&mut store, ctx, t29)?
        .ok_or_else(|| anyhow!("expected task t29 to be complete after resume-process-wait-for-timeout-ok"))?;
    let v = match out29 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t29 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "finished=true" {
        return Err(anyhow!(
            "expected 'finished=true' from task t29, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 30: typed per-op WIT (process-stdin-write) ---
    let t30 = rt.call_start_task(&mut store, ctx, 30, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t30, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessStdinWrite(r) => {
            if r.process_id != 77 {
                return Err(anyhow!(
                    "unexpected process-stdin-write request: process-id={}",
                    r.process_id
                ));
            }
            if r.bytes != vec![1, 2, 3] {
                return Err(anyhow!("unexpected process-stdin-write bytes"));
            }
        }
        _ => return Err(anyhow!("expected process-stdin-write")),
    }

    rt.call_resume_process_stdin_write_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-stdin-write-ok, got {}",
            more.len()
        ));
    }

    let out30 = rt
        .call_poll_task(&mut store, ctx, t30)?
        .ok_or_else(|| anyhow!("expected task t30 to be complete after resume-process-stdin-write-ok"))?;
    let v = match out30 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t30 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "stdin-wrote=3" {
        return Err(anyhow!(
            "expected 'stdin-wrote=3' from task t30, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 31: typed per-op WIT (process-stdout-read) ---
    let t31 = rt.call_start_task(&mut store, ctx, 31, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t31, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessStdoutRead(r) => {
            if r.process_id != 77 || r.max_bytes != 4 {
                return Err(anyhow!(
                    "unexpected process-stdout-read request: process-id={} max-bytes={}",
                    r.process_id,
                    r.max_bytes
                ));
            }
        }
        _ => return Err(anyhow!("expected process-stdout-read")),
    }

    rt.call_resume_process_stdout_read_ok(&mut store, ctx, suspensions[0], &[1u8, 2, 3])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-stdout-read-ok, got {}",
            more.len()
        ));
    }

    let out31 = rt
        .call_poll_task(&mut store, ctx, t31)?
        .ok_or_else(|| anyhow!("expected task t31 to be complete after resume-process-stdout-read-ok"))?;
    let v = match out31 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t31 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "stdout=3 first=1" {
        return Err(anyhow!(
            "expected 'stdout=3 first=1' from task t31, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 32: typed per-op WIT (process-stderr-read) ---
    let t32 = rt.call_start_task(&mut store, ctx, 32, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t32, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessStderrRead(r) => {
            if r.process_id != 77 || r.max_bytes != 4 {
                return Err(anyhow!(
                    "unexpected process-stderr-read request: process-id={} max-bytes={}",
                    r.process_id,
                    r.max_bytes
                ));
            }
        }
        _ => return Err(anyhow!("expected process-stderr-read")),
    }

    rt.call_resume_process_stderr_read_ok(&mut store, ctx, suspensions[0], &[4u8, 5])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-stderr-read-ok, got {}",
            more.len()
        ));
    }

    let out32 = rt
        .call_poll_task(&mut store, ctx, t32)?
        .ok_or_else(|| anyhow!("expected task t32 to be complete after resume-process-stderr-read-ok"))?;
    let v = match out32 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t32 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "stderr=2 first=4" {
        return Err(anyhow!(
            "expected 'stderr=2 first=4' from task t32, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 33: typed per-op WIT (process-release) ---
    let t33 = rt.call_start_task(&mut store, ctx, 33, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t33, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::ProcessRelease(r) => {
            if r.process_id != 77 {
                return Err(anyhow!(
                    "unexpected process-release request: process-id={}",
                    r.process_id
                ));
            }
        }
        _ => return Err(anyhow!("expected process-release")),
    }

    rt.call_resume_process_release_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-release-ok, got {}",
            more.len()
        ));
    }

    let out33 = rt
        .call_poll_task(&mut store, ctx, t33)?
        .ok_or_else(|| anyhow!("expected task t33 to be complete after resume-process-release-ok"))?;
    let v = match out33 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t33 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "released" {
        return Err(anyhow!("expected 'released' from task t33, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 34: typed per-op WIT (file-is-directory) ---
    let t34 = rt.call_start_task(&mut store, ctx, 34, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t34, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsDirectory(r) => {
            if r.path != "fixtures" {
                return Err(anyhow!(
                    "unexpected file-is-directory request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-directory")),
    }

    rt.call_resume_file_is_directory_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-directory-ok, got {}",
            more.len()
        ));
    }

    let out34 = rt
        .call_poll_task(&mut store, ctx, t34)?
        .ok_or_else(|| anyhow!("expected task t34 to be complete after resume-file-is-directory-ok"))?;
    let v = match out34 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t34 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-directory=true" {
        return Err(anyhow!(
            "expected 'is-directory=true' from task t34, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 35: typed per-op WIT (file-is-regular-file) ---
    let t35 = rt.call_start_task(&mut store, ctx, 35, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t35, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsRegularFile(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-is-regular-file request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-regular-file")),
    }

    rt.call_resume_file_is_regular_file_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-regular-file-ok, got {}",
            more.len()
        ));
    }

    let out35 = rt
        .call_poll_task(&mut store, ctx, t35)?
        .ok_or_else(|| anyhow!("expected task t35 to be complete after resume-file-is-regular-file-ok"))?;
    let v = match out35 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t35 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-regular-file=true" {
        return Err(anyhow!(
            "expected 'is-regular-file=true' from task t35, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 36: typed per-op WIT (file-is-readable) ---
    let t36 = rt.call_start_task(&mut store, ctx, 36, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t36, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsReadable(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-is-readable request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-readable")),
    }

    rt.call_resume_file_is_readable_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-readable-ok, got {}",
            more.len()
        ));
    }

    let out36 = rt
        .call_poll_task(&mut store, ctx, t36)?
        .ok_or_else(|| anyhow!("expected task t36 to be complete after resume-file-is-readable-ok"))?;
    let v = match out36 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t36 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-readable=true" {
        return Err(anyhow!(
            "expected 'is-readable=true' from task t36, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 37: typed per-op WIT (file-is-symbolic-link) ---
    let t37 = rt.call_start_task(&mut store, ctx, 37, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t37, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsSymbolicLink(r) => {
            if r.path != "fixtures/link.txt" {
                return Err(anyhow!(
                    "unexpected file-is-symbolic-link request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-symbolic-link")),
    }

    rt.call_resume_file_is_symbolic_link_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-symbolic-link-ok, got {}",
            more.len()
        ));
    }

    let out37 = rt
        .call_poll_task(&mut store, ctx, t37)?
        .ok_or_else(|| anyhow!("expected task t37 to be complete after resume-file-is-symbolic-link-ok"))?;
    let v = match out37 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t37 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-symbolic-link=true" {
        return Err(anyhow!(
            "expected 'is-symbolic-link=true' from task t37, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 38: typed per-op WIT (file-is-writable) ---
    let t38 = rt.call_start_task(&mut store, ctx, 38, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t38, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsWritable(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-is-writable request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-writable")),
    }

    rt.call_resume_file_is_writable_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-writable-ok, got {}",
            more.len()
        ));
    }

    let out38 = rt
        .call_poll_task(&mut store, ctx, t38)?
        .ok_or_else(|| anyhow!("expected task t38 to be complete after resume-file-is-writable-ok"))?;
    let v = match out38 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t38 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-writable=true" {
        return Err(anyhow!(
            "expected 'is-writable=true' from task t38, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 39: typed per-op WIT (file-is-executable) ---
    let t39 = rt.call_start_task(&mut store, ctx, 39, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t39, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileIsExecutable(r) => {
            if r.path != "fixtures/bin" {
                return Err(anyhow!(
                    "unexpected file-is-executable request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-is-executable")),
    }

    rt.call_resume_file_is_executable_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-is-executable-ok, got {}",
            more.len()
        ));
    }

    let out39 = rt
        .call_poll_task(&mut store, ctx, t39)?
        .ok_or_else(|| anyhow!("expected task t39 to be complete after resume-file-is-executable-ok"))?;
    let v = match out39 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t39 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "is-executable=true" {
        return Err(anyhow!(
            "expected 'is-executable=true' from task t39, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 40: typed per-op WIT (file-access-time) ---
    let t40 = rt.call_start_task(&mut store, ctx, 40, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t40, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileAccessTime(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-access-time request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-access-time")),
    }

    rt.call_resume_file_access_time_ok(&mut store, ctx, suspensions[0], 111)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-access-time-ok, got {}",
            more.len()
        ));
    }

    let out40 = rt
        .call_poll_task(&mut store, ctx, t40)?
        .ok_or_else(|| anyhow!("expected task t40 to be complete after resume-file-access-time-ok"))?;
    let v = match out40 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t40 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "access-ms=111" {
        return Err(anyhow!(
            "expected 'access-ms=111' from task t40, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 41: typed per-op WIT (file-creation-time) ---
    let t41 = rt.call_start_task(&mut store, ctx, 41, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t41, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileCreationTime(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-creation-time request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-creation-time")),
    }

    rt.call_resume_file_creation_time_ok(&mut store, ctx, suspensions[0], 222)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-creation-time-ok, got {}",
            more.len()
        ));
    }

    let out41 = rt
        .call_poll_task(&mut store, ctx, t41)?
        .ok_or_else(|| anyhow!("expected task t41 to be complete after resume-file-creation-time-ok"))?;
    let v = match out41 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t41 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "creation-ms=222" {
        return Err(anyhow!(
            "expected 'creation-ms=222' from task t41, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 42: typed per-op WIT (file-modification-time) ---
    let t42 = rt.call_start_task(&mut store, ctx, 42, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t42, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileModificationTime(r) => {
            if r.path != "fixtures/hello.txt" {
                return Err(anyhow!(
                    "unexpected file-modification-time request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-modification-time")),
    }

    rt.call_resume_file_modification_time_ok(&mut store, ctx, suspensions[0], 333)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-modification-time-ok, got {}",
            more.len()
        ));
    }

    let out42 = rt
        .call_poll_task(&mut store, ctx, t42)?
        .ok_or_else(|| anyhow!("expected task t42 to be complete after resume-file-modification-time-ok"))?;
    let v = match out42 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t42 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "mod-ms=333" {
        return Err(anyhow!(
            "expected 'mod-ms=333' from task t42, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 43: typed per-op WIT (file-write-bytes ok) ---
    let t43 = rt.call_start_task(&mut store, ctx, 43, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t43, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::FileWriteBytes(_)) {
        return Err(anyhow!("expected file-write-bytes for task t43"));
    }

    rt.call_resume_file_write_bytes_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-write-bytes-ok, got {}",
            more.len()
        ));
    }

    let out43 = rt
        .call_poll_task(&mut store, ctx, t43)?
        .ok_or_else(|| anyhow!("expected task t43 to be complete after resume-file-write-bytes-ok"))?;
    let v = match out43 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t43 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "write-bytes-ok" {
        return Err(anyhow!(
            "expected 'write-bytes-ok' from task t43, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 44: typed per-op WIT (file-append ok) ---
    let t44 = rt.call_start_task(&mut store, ctx, 44, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t44, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileAppend(r) => {
            if r.path != "out/append.txt" || r.data != "hello" {
                return Err(anyhow!("unexpected file-append request"));
            }
        }
        _ => return Err(anyhow!("expected file-append")),
    }

    rt.call_resume_file_append_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-append-ok, got {}",
            more.len()
        ));
    }

    let out44 = rt
        .call_poll_task(&mut store, ctx, t44)?
        .ok_or_else(|| anyhow!("expected task t44 to be complete after resume-file-append-ok"))?;
    let v = match out44 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t44 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "append-ok" {
        return Err(anyhow!("expected 'append-ok' from task t44, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 45: typed per-op WIT (file-append-bytes ok) ---
    let t45 = rt.call_start_task(&mut store, ctx, 45, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t45, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileAppendBytes(r) => {
            if r.path != "out/append.bin" {
                return Err(anyhow!(
                    "unexpected file-append-bytes request: path={}",
                    r.path
                ));
            }
            if r.bytes != vec![4, 5, 6] {
                return Err(anyhow!("unexpected file-append-bytes bytes"));
            }
        }
        _ => return Err(anyhow!("expected file-append-bytes")),
    }

    rt.call_resume_file_append_bytes_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-append-bytes-ok, got {}",
            more.len()
        ));
    }

    let out45 = rt
        .call_poll_task(&mut store, ctx, t45)?
        .ok_or_else(|| anyhow!("expected task t45 to be complete after resume-file-append-bytes-ok"))?;
    let v = match out45 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t45 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "append-bytes-ok" {
        return Err(anyhow!(
            "expected 'append-bytes-ok' from task t45, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 46: typed per-op WIT (file-truncate ok) ---
    let t46 = rt.call_start_task(&mut store, ctx, 46, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t46, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileTruncate(r) => {
            if r.path != "out/trunc.txt" {
                return Err(anyhow!(
                    "unexpected file-truncate request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-truncate")),
    }

    rt.call_resume_file_truncate_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-truncate-ok, got {}",
            more.len()
        ));
    }

    let out46 = rt
        .call_poll_task(&mut store, ctx, t46)?
        .ok_or_else(|| anyhow!("expected task t46 to be complete after resume-file-truncate-ok"))?;
    let v = match out46 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t46 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "truncate-ok" {
        return Err(anyhow!(
            "expected 'truncate-ok' from task t46, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 47: typed per-op WIT (file-mkdir ok) ---
    let t47 = rt.call_start_task(&mut store, ctx, 47, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t47, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileMkdir(r) => {
            if r.path != "out/dir" {
                return Err(anyhow!("unexpected file-mkdir request: path={}", r.path));
            }
        }
        _ => return Err(anyhow!("expected file-mkdir")),
    }

    rt.call_resume_file_mkdir_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-mkdir-ok, got {}",
            more.len()
        ));
    }

    let out47 = rt
        .call_poll_task(&mut store, ctx, t47)?
        .ok_or_else(|| anyhow!("expected task t47 to be complete after resume-file-mkdir-ok"))?;
    let v = match out47 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t47 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "mkdir-ok" {
        return Err(anyhow!("expected 'mkdir-ok' from task t47, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 48: typed per-op WIT (file-mkdirs ok) ---
    let t48 = rt.call_start_task(&mut store, ctx, 48, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t48, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    match req {
        OpRequest::FileMkdirs(r) => {
            if r.path != "out/dir/nested" {
                return Err(anyhow!(
                    "unexpected file-mkdirs request: path={}",
                    r.path
                ));
            }
        }
        _ => return Err(anyhow!("expected file-mkdirs")),
    }

    rt.call_resume_file_mkdirs_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-file-mkdirs-ok, got {}",
            more.len()
        ));
    }

    let out48 = rt
        .call_poll_task(&mut store, ctx, t48)?
        .ok_or_else(|| anyhow!("expected task t48 to be complete after resume-file-mkdirs-ok"))?;
    let v = match out48 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t48 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "mkdirs-ok" {
        return Err(anyhow!("expected 'mkdirs-ok' from task t48, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 49: typed per-op WIT (process-exit-value) ---
    let t49 = rt.call_start_task(&mut store, ctx, 49, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t49, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::ProcessExitValue(_)) {
        return Err(anyhow!("expected process-exit-value"));
    }

    rt.call_resume_process_exit_value_ok(&mut store, ctx, suspensions[0], 7)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-exit-value-ok, got {}",
            more.len()
        ));
    }

    let out49 = rt
        .call_poll_task(&mut store, ctx, t49)?
        .ok_or_else(|| anyhow!("expected task t49 to be complete after resume-process-exit-value-ok"))?;
    let v = match out49 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t49 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "exit=7" {
        return Err(anyhow!("expected 'exit=7' from task t49, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 50: typed per-op WIT (process-is-alive) ---
    let t50 = rt.call_start_task(&mut store, ctx, 50, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t50, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::ProcessIsAlive(_)) {
        return Err(anyhow!("expected process-is-alive"));
    }

    rt.call_resume_process_is_alive_ok(&mut store, ctx, suspensions[0], true)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-is-alive-ok, got {}",
            more.len()
        ));
    }

    let out50 = rt
        .call_poll_task(&mut store, ctx, t50)?
        .ok_or_else(|| anyhow!("expected task t50 to be complete after resume-process-is-alive-ok"))?;
    let v = match out50 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t50 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "alive=true" {
        return Err(anyhow!(
            "expected 'alive=true' from task t50, got '{s}'"
        ));
    }
    v.resource_drop(&mut store)?;

    // --- def 51: typed per-op WIT (process-stop) ---
    let t51 = rt.call_start_task(&mut store, ctx, 51, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t51, got {}",
            suspensions.len()
        ));
    }

    let req = rt.call_suspension_request(&mut store, ctx, suspensions[0])?;
    if !matches!(req, OpRequest::ProcessStop(_)) {
        return Err(anyhow!("expected process-stop"));
    }

    rt.call_resume_process_stop_ok(&mut store, ctx, suspensions[0])?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-process-stop-ok, got {}",
            more.len()
        ));
    }

    let out51 = rt
        .call_poll_task(&mut store, ctx, t51)?
        .ok_or_else(|| anyhow!("expected task t51 to be complete after resume-process-stop-ok"))?;
    let v = match out51 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t51 unexpectedly threw")),
    };
    let s = rt.call_unbox_string(&mut store, ctx, v)?;
    if s != "stopped" {
        return Err(anyhow!("expected 'stopped' from task t51, got '{s}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 2: start two tasks; ensure multiple in-flight suspensions ---
    let t1 = rt.call_start_task(&mut store, ctx, 2, &[])?;
    let t2 = rt.call_start_task(&mut store, ctx, 2, &[])?;

    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 2 {
        return Err(anyhow!(
            "expected 2 suspensions after sched-step, got {}",
            suspensions.len()
        ));
    }

    // Peek both suspensions (metadata is stable even if both ops are identical).
    for s in &suspensions {
        let info = rt.call_suspension_peek(&mut store, ctx, *s)?;
        if info.eff_id != 10 || info.op_id != 20 {
            return Err(anyhow!(
                "unexpected suspension-info: eff-id={} op-id={}",
                info.eff_id,
                info.op_id
            ));
        }
    }

    if rt.call_poll_task(&mut store, ctx, t1)?.is_some() {
        return Err(anyhow!("expected task t1 incomplete before resumption"));
    }
    if rt.call_poll_task(&mut store, ctx, t2)?.is_some() {
        return Err(anyhow!("expected task t2 incomplete before resumption"));
    }

    // Resume both with different values.
    let v1 = rt.call_box_string(&mut store, ctx, "resumed ok #1")?;
    rt.call_resume_ok(&mut store, ctx, suspensions[0], v1)?;
    v1.resource_drop(&mut store)?;

    let v2 = rt.call_box_string(&mut store, ctx, "resumed ok #2")?;
    rt.call_resume_ok(&mut store, ctx, suspensions[1], v2)?;
    v2.resource_drop(&mut store)?;

    // Drive the scheduler to completion.
    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resumption, got {}",
            more.len()
        ));
    }

    let out1 = rt
        .call_poll_task(&mut store, ctx, t1)?
        .ok_or_else(|| anyhow!("expected task t1 to be complete after resumption"))?;
    let out2 = rt
        .call_poll_task(&mut store, ctx, t2)?
        .ok_or_else(|| anyhow!("expected task t2 to be complete after resumption"))?;

    let v = match out1 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t1 unexpectedly threw")),
    };
    let resumed = rt.call_unbox_string(&mut store, ctx, v)?;
    if resumed != "resumed ok #1" {
        return Err(anyhow!("expected 'resumed ok #1', got '{resumed}'"));
    }
    v.resource_drop(&mut store)?;

    let v = match out2 {
        TaskOutcome::Ok(v) => v,
        TaskOutcome::Thrown(_) => return Err(anyhow!("task t2 unexpectedly threw")),
    };
    let resumed = rt.call_unbox_string(&mut store, ctx, v)?;
    if resumed != "resumed ok #2" {
        return Err(anyhow!("expected 'resumed ok #2', got '{resumed}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 2: suspended + resume-throw ---
    let t3 = rt.call_start_task(&mut store, ctx, 2, &[])?;
    let suspensions = rt.call_sched_step(&mut store, ctx, 10)?;
    if suspensions.len() != 1 {
        return Err(anyhow!(
            "expected 1 suspension for task t3, got {}",
            suspensions.len()
        ));
    }

    let exn_in = rt.call_box_string(&mut store, ctx, "resumed threw")?;
    rt.call_resume_throw(&mut store, ctx, suspensions[0], exn_in)?;
    exn_in.resource_drop(&mut store)?;

    let more = rt.call_sched_step(&mut store, ctx, 10)?;
    if !more.is_empty() {
        return Err(anyhow!(
            "expected no further suspensions after resume-throw, got {}",
            more.len()
        ));
    }

    let out3 = rt
        .call_poll_task(&mut store, ctx, t3)?
        .ok_or_else(|| anyhow!("expected task t3 to be complete after resume-throw"))?;
    let v = match out3 {
        TaskOutcome::Thrown(v) => v,
        TaskOutcome::Ok(_) => return Err(anyhow!("expected thrown from task t3, got ok")),
    };

    let thrown = rt.call_unbox_string(&mut store, ctx, v)?;
    if thrown != "resumed threw" {
        return Err(anyhow!("expected 'resumed threw', got '{thrown}'"));
    }
    v.resource_drop(&mut store)?;

    // --- def 3: thrown ---
    let exec = rt.call_invoke(&mut store, ctx, 3, &[])?;
    let thrown_value = match exec {
        Exec::Thrown(v) => v,
        Exec::Ok(_) => return Err(anyhow!("expected thrown for def-id=3, got ok")),
        Exec::Suspended(_) => return Err(anyhow!("expected thrown for def-id=3, got suspended")),
    };

    let msg = rt.call_unbox_string(&mut store, ctx, thrown_value)?;
    if msg != "thrown from flix-smoke" {
        return Err(anyhow!("unexpected thrown payload: '{msg}'"));
    }

    thrown_value.resource_drop(&mut store)?;

    // Clean up guest resources explicitly.
    ctx.resource_drop(&mut store)?;

    eprintln!("wasm smoke OK: add + typed ops + multi-suspension scheduling + throw all passed (sum={sum})");
    Ok(())
}
