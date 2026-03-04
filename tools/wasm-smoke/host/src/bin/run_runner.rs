use anyhow::{anyhow, Context, Result};
use flix_wasm_runner::{
    bindings,
    host::StdHostHandlers,
    runner::FlixRunner,
};
use std::fs;
use std::path::PathBuf;
use wasmtime::{
    Config, Engine, Store,
    component::{Component, HasSelf, Linker},
};

use bindings::flix::sys::sys::{Capability, Host as SysHost, LogLevel};

struct State;

impl SysHost for State {
    fn log(&mut self, level: LogLevel, msg: String) {
        eprintln!("[guest:{level:?}] {msg}");
    }

    fn time_now_ms(&mut self) -> i64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        now.as_millis() as i64
    }

    fn random_bytes(&mut self, len: u32) -> Vec<u8> {
        // Deterministic (but non-cryptographic) bytes for tests.
        (0..len).map(|i| (i as u8).wrapping_mul(31)).collect()
    }

    fn has_capability(&mut self, cap: Capability) -> bool {
        matches!(
            cap,
            Capability::Filesystem | Capability::Http | Capability::Sockets | Capability::Process
        )
    }
}

fn command_exists(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };

    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            let exe = dir.join(format!("{name}.exe"));
            if exe.is_file() {
                return true;
            }
        }
    }

    false
}

fn make_temp_sandbox(prefix: &str) -> Result<PathBuf> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut dir = std::env::temp_dir();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    dir.push(format!("{prefix}{}-{now}", std::process::id()));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn rm_rf(dir: &PathBuf) {
    let _ = fs::remove_dir_all(dir);
}

fn maybe_drop_value(
    store: &mut Store<State>,
    v: bindings::exports::flix::runtime::runtime::Value,
) {
    let _ = v.resource_drop(store);
}

fn run_task(
    store: &mut Store<State>,
    rt: &bindings::exports::flix::runtime::runtime::Guest,
    ctx: bindings::exports::flix::runtime::runtime::Ctx,
    runner: &FlixRunner,
    handlers: &mut StdHostHandlers,
    def_id: u64,
) -> Result<bindings::exports::flix::runtime::runtime::TaskOutcome> {
    let task_id = rt.call_start_task(&mut *store, ctx, def_id, &[])?;
    runner.run_task_to_completion(&mut *store, rt, ctx, task_id, handlers)
}

fn assert_ok_i32(
    store: &mut Store<State>,
    rt: &bindings::exports::flix::runtime::runtime::Guest,
    ctx: bindings::exports::flix::runtime::runtime::Ctx,
    runner: &FlixRunner,
    handlers: &mut StdHostHandlers,
    def_id: u64,
    expected: i32,
) -> Result<()> {
    let out = run_task(store, rt, ctx, runner, handlers, def_id)?;
    match out {
        bindings::exports::flix::runtime::runtime::TaskOutcome::Ok(v) => {
            let got = rt.call_unbox_i32(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            if got != expected {
                return Err(anyhow!("expected {expected} for def {def_id}, got {got}"));
            }
            Ok(())
        }
        bindings::exports::flix::runtime::runtime::TaskOutcome::Thrown(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            Err(anyhow!("expected ok for def {def_id}, got thrown: {got}"))
        }
    }
}

fn assert_ok_string(
    store: &mut Store<State>,
    rt: &bindings::exports::flix::runtime::runtime::Guest,
    ctx: bindings::exports::flix::runtime::runtime::Ctx,
    runner: &FlixRunner,
    handlers: &mut StdHostHandlers,
    def_id: u64,
    expected: &str,
) -> Result<()> {
    let out = run_task(store, rt, ctx, runner, handlers, def_id)?;
    match out {
        bindings::exports::flix::runtime::runtime::TaskOutcome::Ok(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            if got != expected {
                return Err(anyhow!("expected '{expected}' for def {def_id}, got '{got}'"));
            }
            Ok(())
        }
        bindings::exports::flix::runtime::runtime::TaskOutcome::Thrown(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            Err(anyhow!("expected ok for def {def_id}, got thrown: {got}"))
        }
    }
}

fn assert_thrown_string(
    store: &mut Store<State>,
    rt: &bindings::exports::flix::runtime::runtime::Guest,
    ctx: bindings::exports::flix::runtime::runtime::Ctx,
    runner: &FlixRunner,
    handlers: &mut StdHostHandlers,
    def_id: u64,
    expected: &str,
) -> Result<()> {
    let out = run_task(store, rt, ctx, runner, handlers, def_id)?;
    match out {
        bindings::exports::flix::runtime::runtime::TaskOutcome::Thrown(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            if got != expected {
                return Err(anyhow!("expected '{expected}' for def {def_id}, got '{got}'"));
            }
            Ok(())
        }
        bindings::exports::flix::runtime::runtime::TaskOutcome::Ok(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            Err(anyhow!("expected thrown for def {def_id}, got ok: {got}"))
        }
    }
}

fn assert_thrown_starts_with(
    store: &mut Store<State>,
    rt: &bindings::exports::flix::runtime::runtime::Guest,
    ctx: bindings::exports::flix::runtime::runtime::Ctx,
    runner: &FlixRunner,
    handlers: &mut StdHostHandlers,
    def_id: u64,
    prefix: &str,
) -> Result<()> {
    let out = run_task(store, rt, ctx, runner, handlers, def_id)?;
    match out {
        bindings::exports::flix::runtime::runtime::TaskOutcome::Thrown(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            if !got.starts_with(prefix) {
                return Err(anyhow!(
                    "expected thrown string for def {def_id} to start with '{prefix}', got '{got}'"
                ));
            }
            Ok(())
        }
        bindings::exports::flix::runtime::runtime::TaskOutcome::Ok(v) => {
            let got = rt.call_unbox_string(&mut *store, ctx, v)?;
            maybe_drop_value(&mut *store, v);
            Err(anyhow!("expected thrown for def {def_id}, got ok: {got}"))
        }
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

    let has_node = command_exists("node");
    let mut store = Store::new(&engine, State);
    let flix = bindings::Flix::instantiate(&mut store, &component, &linker)?;
    let rt = flix.flix_runtime_runtime();

    let ctx = rt.call_new_ctx(&mut store)?;

    let sandbox = make_temp_sandbox("flix-wasm-smoke-")?;
    let fixtures_dir = sandbox.join("fixtures");
    let out_dir = sandbox.join("out");

    fs::create_dir_all(&fixtures_dir)?;
    fs::create_dir_all(&out_dir)?;
    fs::write(fixtures_dir.join("hello.txt"), "hello")?;
    fs::write(fixtures_dir.join("lines.txt"), "a\nb\n")?;
    fs::write(fixtures_dir.join("bytes.bin"), [1u8, 2, 3])?;

    let runner = FlixRunner { budget: 10 };
    let mut handlers = StdHostHandlers::new(sandbox.clone());

    // def 4: timer-sleep (runner default)
    assert_ok_i32(&mut store, rt, ctx, &runner, &mut handlers, 4, 123)?;

    // def 5: http-request (handler stub)
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 5, "200 hello")?;

    // --- filesystem ops (real sandboxed host handlers) ---
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 16, "exists=true")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 17, "size=5")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 18, "read=hello")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 19, "lines=2 first=a")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 20, "bytes=3 first=1")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 21, "list=3 first=bytes.bin")?;
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 22, "write-ok")?;
    assert_thrown_string(&mut store, rt, ctx, &runner, &mut handlers, 54, "8 not a directory")?;
    assert_thrown_starts_with(&mut store, rt, ctx, &runner, &mut handlers, 55, "14 ")?;

    let wrote = fs::read_to_string(out_dir.join("write.txt"))?;
    if wrote != "hello" {
        return Err(anyhow!("expected out/write.txt to contain 'hello', got '{wrote}'"));
    }

    // def 52: TCP roundtrip (real host handlers)
    assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 52, "tcp-ok")?;

    // def 53: Process roundtrip (real host handlers). Skip if `node` isn't available.
    if has_node {
        assert_ok_string(&mut store, rt, ctx, &runner, &mut handlers, 53, "proc-ok")?;
    } else {
        eprintln!("wasmtime runner: skipping def 53 (node not found in PATH)");
    }

    ctx.resource_drop(&mut store)?;
    rm_rf(&sandbox);

    eprintln!("wasmtime runner smoke OK: fs + tcp");
    Ok(())
}
