pub mod bindings {
    wasmtime::component::bindgen!({
        path: "../../docs/planning/native-backend/wit/flix-bindings",
        world: "flix",
    });
}

pub mod host;
pub mod runner;

