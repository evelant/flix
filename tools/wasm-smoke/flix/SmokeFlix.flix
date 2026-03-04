///
/// Small Flix program used by `tools/wasm-smoke/run_flix.sh` to validate that:
/// - the Flix LLVM-wasm toolchain produces a runnable component + JS package,
/// - IO primops suspend/resume correctly through the WIT substrate,
/// - the JS host runner can drive the cooperative scheduler.
///
/// This is intentionally minimal and should stay that way.
///

mod SmokeFlix {

    @Export pub def smoke(url: String, file: String): String \ IO = {
        let fileRes = FileRead.runWithIO(_ -> FileRead.read(file));
        let fileStr = match fileRes {
            case Ok(s) => s
            case Err(e) => "file-err:" + ToString.toString(e)
        };

        let httpRes = Http.runWithIO(_ -> Http.get(url, Map.empty()));
        let httpStr = match httpRes {
            case Ok(Http.Response.Response({status = s, headers = _headers, body = b})) => Int32.toString(s) + " " + b
            case Err(e) => "http-err:" + ToString.toString(e)
        };

        fileStr + "|" + httpStr
    }
}
