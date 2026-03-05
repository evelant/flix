///
/// A small "real program" fixture for the LLVM-native backend.
///
/// Exercises:
/// - process spawn + wait (`ProcessWithResult`)
/// - stdout piping (`Readable[Process.StdOut]`)
///
def expectOk(res: Result[a, b]): b with ToString[a] = match res {
    case Ok(v) => v
    case Err(e) => bug!("unexpected Err: " + ToString.toString(e))
}

def main(): Unit \ IO =
    run {
        let ph = ProcessWithResult.exec("zig", "version" :: Nil) |> expectOk;

        region rc {
            let out = Process.StdOut.StdOut(ph);
            let buf: Array[Int8, rc] = Array.empty(rc, 64);
            let n = Readable.read(buf, out) |> expectOk;
            let _ =
                if (n <= 0i32)
                    bug!("process-spawn: expected stdout")
                else ();

            // `zig version` should begin with an ASCII digit.
            let b0 = Array.get(0, buf);
            let _ =
                if (b0 < 48i8 or b0 > 57i8)
                    bug!("process-spawn: unexpected stdout first byte: " + Int8.toString(b0))
                else ();

            ()
        };

        let exitCode = ProcessWithResult.waitFor(ph) |> expectOk;
        let _ =
            if (exitCode != 0i32)
                bug!("process-spawn: unexpected exit code: " + Int32.toString(exitCode))
            else ();

        let _ = ProcessHandle.release(ph) |> expectOk;
        println("process-spawn: ok");
        ()
    } with ProcessWithResult.runWithIO

