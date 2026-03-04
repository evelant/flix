import { runtime } from "../browser-out/flix-smoke.component.js";

const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
const maybeDispose = (x) => {
  const fn = x?.[disposeSym];
  if (typeof fn === "function") fn.call(x);
};

const ctx = runtime.newCtx();

// --- def 1: add two i32s ---
const a = runtime.boxI32(ctx, 20);
const b = runtime.boxI32(ctx, 22);

const exec = runtime.invoke(ctx, 1n, [a, b]);
if (exec.tag !== "ok") {
  throw new Error(`expected ok, got ${exec.tag}`);
}

const sum = runtime.unboxI32(ctx, exec.val);
if (sum !== 42) {
  throw new Error(`expected 42, got ${sum}`);
}

maybeDispose(exec.val);
maybeDispose(b);
maybeDispose(a);

// --- def 2: invoke can suspend and yields a pollable task-id ---
const execSusp = runtime.invoke(ctx, 2n, []);
if (execSusp.tag !== "suspended") {
  throw new Error(`expected suspended, got ${execSusp.tag}`);
}

const info0 = runtime.suspensionPeek(ctx, execSusp.val.suspension);
if (info0.effId !== 10n || info0.opId !== 20n) {
  throw new Error(`unexpected suspension-info: effId=${info0.effId} opId=${info0.opId}`);
}

if (runtime.pollTask(ctx, execSusp.val.task) != null) {
  throw new Error("expected invoke(def=2) task incomplete before resumption");
}

const resumeIn0 = runtime.boxString(ctx, "resumed via invoke");
runtime.resumeOk(ctx, execSusp.val.suspension, resumeIn0);
maybeDispose(resumeIn0);

const more0 = runtime.schedStep(ctx, 10);
if (more0.length !== 0) {
  throw new Error(`expected no further suspensions after invoke-resume, got ${more0.length}`);
}

const out0 = runtime.pollTask(ctx, execSusp.val.task);
if (out0?.tag !== "ok") {
  throw new Error(`expected ok for invoke(def=2) task, got ${out0?.tag}`);
}
const resumed0 = runtime.unboxString(ctx, out0.val);
if (resumed0 !== "resumed via invoke") {
  throw new Error(`expected 'resumed via invoke', got '${resumed0}'`);
}
maybeDispose(out0.val);

// --- def 4: typed per-op WIT (timer-sleep) ---
const t4 = runtime.startTask(ctx, 4n, []);
const susp4 = runtime.schedStep(ctx, 10);
if (susp4.length !== 1) {
  throw new Error(`expected 1 suspension for task t4, got ${susp4.length}`);
}

const req4 = runtime.suspensionRequest(ctx, susp4[0]);
if (req4.tag !== "timer-sleep") {
  throw new Error(`expected timer-sleep request, got ${req4.tag}`);
}
if (req4.val.ms !== 5n) {
  throw new Error(`expected timer-sleep ms=5, got ${req4.val.ms}`);
}

runtime.resumeTimerSleep(ctx, susp4[0]);

const more4 = runtime.schedStep(ctx, 10);
if (more4.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTimerSleep, got ${more4.length}`);
}

const out4 = runtime.pollTask(ctx, t4);
if (out4?.tag !== "ok") {
  throw new Error(`expected ok for task t4, got ${out4?.tag}`);
}
const x4 = runtime.unboxI32(ctx, out4.val);
if (x4 !== 123) {
  throw new Error(`expected 123 for task t4, got ${x4}`);
}
maybeDispose(out4.val);

// --- def 5: typed per-op WIT (http-request ok/err) ---
const t5 = runtime.startTask(ctx, 5n, []);
const susp5 = runtime.schedStep(ctx, 10);
if (susp5.length !== 1) {
  throw new Error(`expected 1 suspension for task t5, got ${susp5.length}`);
}

const req5 = runtime.suspensionRequest(ctx, susp5[0]);
if (req5.tag !== "http-request") {
  throw new Error(`expected http-request request, got ${req5.tag}`);
}
if (req5.val.method !== "GET" || req5.val.url !== "https://example.com/hello") {
  throw new Error(`unexpected http-request: method=${req5.val.method} url=${req5.val.url}`);
}
if (req5.val.body !== undefined) {
  throw new Error("expected http-request body to be absent");
}
if (
  req5.val.headers.length !== 1 ||
  req5.val.headers[0].name !== "x-req" ||
  req5.val.headers[0].value !== "abc"
) {
  throw new Error("unexpected http-request headers");
}

runtime.resumeHttpOk(ctx, susp5[0], {
  status: 200,
  headers: [{ name: "x-foo", value: "bar" }],
  body: "hello",
});

const more5 = runtime.schedStep(ctx, 10);
if (more5.length !== 0) {
  throw new Error(`expected no further suspensions after resumeHttpOk, got ${more5.length}`);
}

const out5 = runtime.pollTask(ctx, t5);
if (out5?.tag !== "ok") {
  throw new Error(`expected ok for task t5, got ${out5?.tag}`);
}
const s5 = runtime.unboxString(ctx, out5.val);
if (s5 !== "200 hello") {
  throw new Error(`expected '200 hello' for task t5, got '${s5}'`);
}
maybeDispose(out5.val);

// http-request err
const t6 = runtime.startTask(ctx, 6n, []);
const susp6 = runtime.schedStep(ctx, 10);
if (susp6.length !== 1) {
  throw new Error(`expected 1 suspension for task t6, got ${susp6.length}`);
}

const req6 = runtime.suspensionRequest(ctx, susp6[0]);
if (req6.tag !== "http-request") {
  throw new Error(`expected http-request request for task t6, got ${req6.tag}`);
}

runtime.resumeHttpErr(ctx, susp6[0], { kindCode: 10, msg: "timeout" });

const more6 = runtime.schedStep(ctx, 10);
if (more6.length !== 0) {
  throw new Error(`expected no further suspensions after resumeHttpErr, got ${more6.length}`);
}

const out6 = runtime.pollTask(ctx, t6);
if (out6?.tag !== "thrown") {
  throw new Error(`expected thrown for task t6, got ${out6?.tag}`);
}
const s6 = runtime.unboxString(ctx, out6.val);
if (s6 !== "10 timeout") {
  throw new Error(`expected '10 timeout' for task t6, got '${s6}'`);
}
maybeDispose(out6.val);

// --- def 7: typed per-op WIT (tcp-socket-connect ok/err) ---
const t7 = runtime.startTask(ctx, 7n, []);
const susp7 = runtime.schedStep(ctx, 10);
if (susp7.length !== 1) {
  throw new Error(`expected 1 suspension for task t7, got ${susp7.length}`);
}

const req7 = runtime.suspensionRequest(ctx, susp7[0]);
if (req7.tag !== "tcp-socket-connect") {
  throw new Error(`expected tcp-socket-connect request, got ${req7.tag}`);
}
if (
  req7.val.port !== 8080 ||
  req7.val.ip.length !== 4 ||
  req7.val.ip[0] !== 127 ||
  req7.val.ip[1] !== 0 ||
  req7.val.ip[2] !== 0 ||
  req7.val.ip[3] !== 1
) {
  throw new Error(`unexpected tcp-socket-connect request: ip=${req7.val.ip} port=${req7.val.port}`);
}

runtime.resumeTcpSocketConnectOk(ctx, susp7[0], 99n);

const more7 = runtime.schedStep(ctx, 10);
if (more7.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpSocketConnectOk, got ${more7.length}`);
}

const out7 = runtime.pollTask(ctx, t7);
if (out7?.tag !== "ok") {
  throw new Error(`expected ok for task t7, got ${out7?.tag}`);
}
const s7 = runtime.unboxString(ctx, out7.val);
if (s7 !== "socket=99") {
  throw new Error(`expected 'socket=99' for task t7, got '${s7}'`);
}
maybeDispose(out7.val);

// tcp-socket-connect err
const t8 = runtime.startTask(ctx, 8n, []);
const susp8 = runtime.schedStep(ctx, 10);
if (susp8.length !== 1) {
  throw new Error(`expected 1 suspension for task t8, got ${susp8.length}`);
}

const req8 = runtime.suspensionRequest(ctx, susp8[0]);
if (req8.tag !== "tcp-socket-connect") {
  throw new Error(`expected tcp-socket-connect request for task t8, got ${req8.tag}`);
}

runtime.resumeTcpSocketConnectErr(ctx, susp8[0], { kindCode: 42, msg: "nope" });

const more8 = runtime.schedStep(ctx, 10);
if (more8.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpSocketConnectErr, got ${more8.length}`);
}

const out8 = runtime.pollTask(ctx, t8);
if (out8?.tag !== "thrown") {
  throw new Error(`expected thrown for task t8, got ${out8?.tag}`);
}
const s8 = runtime.unboxString(ctx, out8.val);
if (s8 !== "42 nope") {
  throw new Error(`expected '42 nope' for task t8, got '${s8}'`);
}
maybeDispose(out8.val);

// --- def 9: typed per-op WIT (tcp-socket-read) ---
const t9 = runtime.startTask(ctx, 9n, []);
const susp9 = runtime.schedStep(ctx, 10);
if (susp9.length !== 1) {
  throw new Error(`expected 1 suspension for task t9, got ${susp9.length}`);
}

const req9 = runtime.suspensionRequest(ctx, susp9[0]);
if (req9.tag !== "tcp-socket-read") {
  throw new Error(`expected tcp-socket-read request, got ${req9.tag}`);
}
if (req9.val.socketId !== 99n || req9.val.maxBytes !== 4) {
  throw new Error(`unexpected tcp-socket-read request: socketId=${req9.val.socketId} maxBytes=${req9.val.maxBytes}`);
}

runtime.resumeTcpSocketReadOk(ctx, susp9[0], new Uint8Array([1, 2, 3]));

const more9 = runtime.schedStep(ctx, 10);
if (more9.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpSocketReadOk, got ${more9.length}`);
}

const out9 = runtime.pollTask(ctx, t9);
if (out9?.tag !== "ok") {
  throw new Error(`expected ok for task t9, got ${out9?.tag}`);
}
const s9 = runtime.unboxString(ctx, out9.val);
if (s9 !== "read=3 first=1") {
  throw new Error(`expected 'read=3 first=1' for task t9, got '${s9}'`);
}
maybeDispose(out9.val);

// --- def 10: typed per-op WIT (tcp-socket-write) ---
const t10 = runtime.startTask(ctx, 10n, []);
const susp10 = runtime.schedStep(ctx, 10);
if (susp10.length !== 1) {
  throw new Error(`expected 1 suspension for task t10, got ${susp10.length}`);
}

const req10 = runtime.suspensionRequest(ctx, susp10[0]);
if (req10.tag !== "tcp-socket-write") {
  throw new Error(`expected tcp-socket-write request, got ${req10.tag}`);
}
if (
  req10.val.socketId !== 99n ||
  req10.val.bytes.length !== 3 ||
  req10.val.bytes[0] !== 7 ||
  req10.val.bytes[1] !== 8 ||
  req10.val.bytes[2] !== 9
) {
  throw new Error("unexpected tcp-socket-write request");
}

runtime.resumeTcpSocketWriteOk(ctx, susp10[0]);

const more10 = runtime.schedStep(ctx, 10);
if (more10.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpSocketWriteOk, got ${more10.length}`);
}

const out10 = runtime.pollTask(ctx, t10);
if (out10?.tag !== "ok") {
  throw new Error(`expected ok for task t10, got ${out10?.tag}`);
}
const s10 = runtime.unboxString(ctx, out10.val);
if (s10 !== "wrote=3") {
  throw new Error(`expected 'wrote=3' for task t10, got '${s10}'`);
}
maybeDispose(out10.val);

// --- def 11: typed per-op WIT (tcp-socket-close) ---
const t11 = runtime.startTask(ctx, 11n, []);
const susp11 = runtime.schedStep(ctx, 10);
if (susp11.length !== 1) {
  throw new Error(`expected 1 suspension for task t11, got ${susp11.length}`);
}

const req11 = runtime.suspensionRequest(ctx, susp11[0]);
if (req11.tag !== "tcp-socket-close") {
  throw new Error(`expected tcp-socket-close request, got ${req11.tag}`);
}
if (req11.val.socketId !== 99n) {
  throw new Error(`unexpected tcp-socket-close request: socketId=${req11.val.socketId}`);
}

runtime.resumeTcpSocketCloseOk(ctx, susp11[0]);

const more11 = runtime.schedStep(ctx, 10);
if (more11.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpSocketCloseOk, got ${more11.length}`);
}

const out11 = runtime.pollTask(ctx, t11);
if (out11?.tag !== "ok") {
  throw new Error(`expected ok for task t11, got ${out11?.tag}`);
}
const s11 = runtime.unboxString(ctx, out11.val);
if (s11 !== "closed") {
  throw new Error(`expected 'closed' for task t11, got '${s11}'`);
}
maybeDispose(out11.val);

// --- def 12: typed per-op WIT (tcp-server-bind) ---
const t12 = runtime.startTask(ctx, 12n, []);
const susp12 = runtime.schedStep(ctx, 10);
if (susp12.length !== 1) {
  throw new Error(`expected 1 suspension for task t12, got ${susp12.length}`);
}

const req12 = runtime.suspensionRequest(ctx, susp12[0]);
if (req12.tag !== "tcp-server-bind") {
  throw new Error(`expected tcp-server-bind request, got ${req12.tag}`);
}
if (
  req12.val.port !== 8080 ||
  req12.val.ip.length !== 4 ||
  req12.val.ip[0] !== 127 ||
  req12.val.ip[1] !== 0 ||
  req12.val.ip[2] !== 0 ||
  req12.val.ip[3] !== 1
) {
  throw new Error(`unexpected tcp-server-bind request: ip=${req12.val.ip} port=${req12.val.port}`);
}

runtime.resumeTcpServerBindOk(ctx, susp12[0], 55n);

const more12 = runtime.schedStep(ctx, 10);
if (more12.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpServerBindOk, got ${more12.length}`);
}

const out12 = runtime.pollTask(ctx, t12);
if (out12?.tag !== "ok") {
  throw new Error(`expected ok for task t12, got ${out12?.tag}`);
}
const s12 = runtime.unboxString(ctx, out12.val);
if (s12 !== "server=55") {
  throw new Error(`expected 'server=55' for task t12, got '${s12}'`);
}
maybeDispose(out12.val);

// --- def 13: typed per-op WIT (tcp-server-accept) ---
const t13 = runtime.startTask(ctx, 13n, []);
const susp13 = runtime.schedStep(ctx, 10);
if (susp13.length !== 1) {
  throw new Error(`expected 1 suspension for task t13, got ${susp13.length}`);
}

const req13 = runtime.suspensionRequest(ctx, susp13[0]);
if (req13.tag !== "tcp-server-accept") {
  throw new Error(`expected tcp-server-accept request, got ${req13.tag}`);
}
if (req13.val.serverId !== 55n) {
  throw new Error(`unexpected tcp-server-accept request: serverId=${req13.val.serverId}`);
}

runtime.resumeTcpServerAcceptOk(ctx, susp13[0], 77n);

const more13 = runtime.schedStep(ctx, 10);
if (more13.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpServerAcceptOk, got ${more13.length}`);
}

const out13 = runtime.pollTask(ctx, t13);
if (out13?.tag !== "ok") {
  throw new Error(`expected ok for task t13, got ${out13?.tag}`);
}
const s13 = runtime.unboxString(ctx, out13.val);
if (s13 !== "socket=77") {
  throw new Error(`expected 'socket=77' for task t13, got '${s13}'`);
}
maybeDispose(out13.val);

// --- def 14: typed per-op WIT (tcp-server-local-port) ---
const t14 = runtime.startTask(ctx, 14n, []);
const susp14 = runtime.schedStep(ctx, 10);
if (susp14.length !== 1) {
  throw new Error(`expected 1 suspension for task t14, got ${susp14.length}`);
}

const req14 = runtime.suspensionRequest(ctx, susp14[0]);
if (req14.tag !== "tcp-server-local-port") {
  throw new Error(`expected tcp-server-local-port request, got ${req14.tag}`);
}
if (req14.val.serverId !== 55n) {
  throw new Error(`unexpected tcp-server-local-port request: serverId=${req14.val.serverId}`);
}

runtime.resumeTcpServerLocalPortOk(ctx, susp14[0], 1234);

const more14 = runtime.schedStep(ctx, 10);
if (more14.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpServerLocalPortOk, got ${more14.length}`);
}

const out14 = runtime.pollTask(ctx, t14);
if (out14?.tag !== "ok") {
  throw new Error(`expected ok for task t14, got ${out14?.tag}`);
}
const s14 = runtime.unboxString(ctx, out14.val);
if (s14 !== "port=1234") {
  throw new Error(`expected 'port=1234' for task t14, got '${s14}'`);
}
maybeDispose(out14.val);

// --- def 15: typed per-op WIT (tcp-server-close) ---
const t15 = runtime.startTask(ctx, 15n, []);
const susp15 = runtime.schedStep(ctx, 10);
if (susp15.length !== 1) {
  throw new Error(`expected 1 suspension for task t15, got ${susp15.length}`);
}

const req15 = runtime.suspensionRequest(ctx, susp15[0]);
if (req15.tag !== "tcp-server-close") {
  throw new Error(`expected tcp-server-close request, got ${req15.tag}`);
}
if (req15.val.serverId !== 55n) {
  throw new Error(`unexpected tcp-server-close request: serverId=${req15.val.serverId}`);
}

runtime.resumeTcpServerCloseOk(ctx, susp15[0]);

const more15 = runtime.schedStep(ctx, 10);
if (more15.length !== 0) {
  throw new Error(`expected no further suspensions after resumeTcpServerCloseOk, got ${more15.length}`);
}

const out15 = runtime.pollTask(ctx, t15);
if (out15?.tag !== "ok") {
  throw new Error(`expected ok for task t15, got ${out15?.tag}`);
}
const s15 = runtime.unboxString(ctx, out15.val);
if (s15 !== "server-closed") {
  throw new Error(`expected 'server-closed' for task t15, got '${s15}'`);
}
maybeDispose(out15.val);

// --- def 16: typed per-op WIT (file-exists) ---
const t16 = runtime.startTask(ctx, 16n, []);
const susp16 = runtime.schedStep(ctx, 10);
if (susp16.length !== 1) {
  throw new Error(`expected 1 suspension for task t16, got ${susp16.length}`);
}

const req16 = runtime.suspensionRequest(ctx, susp16[0]);
if (req16.tag !== "file-exists") {
  throw new Error(`expected file-exists request, got ${req16.tag}`);
}
if (req16.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-exists request: path=${req16.val.path}`);
}

runtime.resumeFileExistsOk(ctx, susp16[0], true);

const more16 = runtime.schedStep(ctx, 10);
if (more16.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileExistsOk, got ${more16.length}`);
}

const out16 = runtime.pollTask(ctx, t16);
if (out16?.tag !== "ok") {
  throw new Error(`expected ok for task t16, got ${out16?.tag}`);
}
const s16 = runtime.unboxString(ctx, out16.val);
if (s16 !== "exists=true") {
  throw new Error(`expected 'exists=true' for task t16, got '${s16}'`);
}
maybeDispose(out16.val);

// --- def 17: typed per-op WIT (file-size) ---
const t17 = runtime.startTask(ctx, 17n, []);
const susp17 = runtime.schedStep(ctx, 10);
if (susp17.length !== 1) {
  throw new Error(`expected 1 suspension for task t17, got ${susp17.length}`);
}

const req17 = runtime.suspensionRequest(ctx, susp17[0]);
if (req17.tag !== "file-size") {
  throw new Error(`expected file-size request, got ${req17.tag}`);
}
if (req17.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-size request: path=${req17.val.path}`);
}

runtime.resumeFileSizeOk(ctx, susp17[0], 1234n);

const more17 = runtime.schedStep(ctx, 10);
if (more17.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileSizeOk, got ${more17.length}`);
}

const out17 = runtime.pollTask(ctx, t17);
if (out17?.tag !== "ok") {
  throw new Error(`expected ok for task t17, got ${out17?.tag}`);
}
const s17 = runtime.unboxString(ctx, out17.val);
if (s17 !== "size=1234") {
  throw new Error(`expected 'size=1234' for task t17, got '${s17}'`);
}
maybeDispose(out17.val);

// --- def 18: typed per-op WIT (file-read) ---
const t18 = runtime.startTask(ctx, 18n, []);
const susp18 = runtime.schedStep(ctx, 10);
if (susp18.length !== 1) {
  throw new Error(`expected 1 suspension for task t18, got ${susp18.length}`);
}

const req18 = runtime.suspensionRequest(ctx, susp18[0]);
if (req18.tag !== "file-read") {
  throw new Error(`expected file-read request, got ${req18.tag}`);
}
if (req18.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-read request: path=${req18.val.path}`);
}

runtime.resumeFileReadOk(ctx, susp18[0], "hello");

const more18 = runtime.schedStep(ctx, 10);
if (more18.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileReadOk, got ${more18.length}`);
}

const out18 = runtime.pollTask(ctx, t18);
if (out18?.tag !== "ok") {
  throw new Error(`expected ok for task t18, got ${out18?.tag}`);
}
const s18 = runtime.unboxString(ctx, out18.val);
if (s18 !== "read=hello") {
  throw new Error(`expected 'read=hello' for task t18, got '${s18}'`);
}
maybeDispose(out18.val);

// --- def 19: typed per-op WIT (file-read-lines) ---
const t19 = runtime.startTask(ctx, 19n, []);
const susp19 = runtime.schedStep(ctx, 10);
if (susp19.length !== 1) {
  throw new Error(`expected 1 suspension for task t19, got ${susp19.length}`);
}

const req19 = runtime.suspensionRequest(ctx, susp19[0]);
if (req19.tag !== "file-read-lines") {
  throw new Error(`expected file-read-lines request, got ${req19.tag}`);
}
if (req19.val.path !== "fixtures/lines.txt") {
  throw new Error(`unexpected file-read-lines request: path=${req19.val.path}`);
}

runtime.resumeFileReadLinesOk(ctx, susp19[0], ["a", "b"]);

const more19 = runtime.schedStep(ctx, 10);
if (more19.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileReadLinesOk, got ${more19.length}`);
}

const out19 = runtime.pollTask(ctx, t19);
if (out19?.tag !== "ok") {
  throw new Error(`expected ok for task t19, got ${out19?.tag}`);
}
const s19 = runtime.unboxString(ctx, out19.val);
if (s19 !== "lines=2 first=a") {
  throw new Error(`expected 'lines=2 first=a' for task t19, got '${s19}'`);
}
maybeDispose(out19.val);

// --- def 20: typed per-op WIT (file-read-bytes) ---
const t20 = runtime.startTask(ctx, 20n, []);
const susp20 = runtime.schedStep(ctx, 10);
if (susp20.length !== 1) {
  throw new Error(`expected 1 suspension for task t20, got ${susp20.length}`);
}

const req20 = runtime.suspensionRequest(ctx, susp20[0]);
if (req20.tag !== "file-read-bytes") {
  throw new Error(`expected file-read-bytes request, got ${req20.tag}`);
}
if (req20.val.path !== "fixtures/bytes.bin") {
  throw new Error(`unexpected file-read-bytes request: path=${req20.val.path}`);
}

runtime.resumeFileReadBytesOk(ctx, susp20[0], new Uint8Array([1, 2, 3]));

const more20 = runtime.schedStep(ctx, 10);
if (more20.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileReadBytesOk, got ${more20.length}`);
}

const out20 = runtime.pollTask(ctx, t20);
if (out20?.tag !== "ok") {
  throw new Error(`expected ok for task t20, got ${out20?.tag}`);
}
const s20 = runtime.unboxString(ctx, out20.val);
if (s20 !== "bytes=3 first=1") {
  throw new Error(`expected 'bytes=3 first=1' for task t20, got '${s20}'`);
}
maybeDispose(out20.val);

// --- def 21: typed per-op WIT (file-list) ---
const t21 = runtime.startTask(ctx, 21n, []);
const susp21 = runtime.schedStep(ctx, 10);
if (susp21.length !== 1) {
  throw new Error(`expected 1 suspension for task t21, got ${susp21.length}`);
}

const req21 = runtime.suspensionRequest(ctx, susp21[0]);
if (req21.tag !== "file-list") {
  throw new Error(`expected file-list request, got ${req21.tag}`);
}
if (req21.val.path !== "fixtures") {
  throw new Error(`unexpected file-list request: path=${req21.val.path}`);
}

runtime.resumeFileListOk(ctx, susp21[0], ["x", "y"]);

const more21 = runtime.schedStep(ctx, 10);
if (more21.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileListOk, got ${more21.length}`);
}

const out21 = runtime.pollTask(ctx, t21);
if (out21?.tag !== "ok") {
  throw new Error(`expected ok for task t21, got ${out21?.tag}`);
}
const s21 = runtime.unboxString(ctx, out21.val);
if (s21 !== "list=2 first=x") {
  throw new Error(`expected 'list=2 first=x' for task t21, got '${s21}'`);
}
maybeDispose(out21.val);

// --- def 22: typed per-op WIT (file-write) ---
const t22 = runtime.startTask(ctx, 22n, []);
const susp22 = runtime.schedStep(ctx, 10);
if (susp22.length !== 1) {
  throw new Error(`expected 1 suspension for task t22, got ${susp22.length}`);
}

const req22 = runtime.suspensionRequest(ctx, susp22[0]);
if (req22.tag !== "file-write") {
  throw new Error(`expected file-write request, got ${req22.tag}`);
}
if (req22.val.path !== "out/write.txt" || req22.val.data !== "hello") {
  throw new Error(`unexpected file-write request: path=${req22.val.path} data=${req22.val.data}`);
}

runtime.resumeFileWriteOk(ctx, susp22[0]);

const more22 = runtime.schedStep(ctx, 10);
if (more22.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileWriteOk, got ${more22.length}`);
}

const out22 = runtime.pollTask(ctx, t22);
if (out22?.tag !== "ok") {
  throw new Error(`expected ok for task t22, got ${out22?.tag}`);
}
const s22 = runtime.unboxString(ctx, out22.val);
if (s22 !== "write-ok") {
  throw new Error(`expected 'write-ok' for task t22, got '${s22}'`);
}
maybeDispose(out22.val);

// --- def 23: typed per-op WIT (file-write-bytes err) ---
const t23 = runtime.startTask(ctx, 23n, []);
const susp23 = runtime.schedStep(ctx, 10);
if (susp23.length !== 1) {
  throw new Error(`expected 1 suspension for task t23, got ${susp23.length}`);
}

const req23 = runtime.suspensionRequest(ctx, susp23[0]);
if (req23.tag !== "file-write-bytes") {
  throw new Error(`expected file-write-bytes request, got ${req23.tag}`);
}
if (req23.val.path !== "out/write.bin") {
  throw new Error(`unexpected file-write-bytes request: path=${req23.val.path}`);
}
if (
  req23.val.bytes.length !== 3 ||
  req23.val.bytes[0] !== 1 ||
  req23.val.bytes[1] !== 2 ||
  req23.val.bytes[2] !== 3
) {
  throw new Error(`unexpected file-write-bytes bytes: ${req23.val.bytes}`);
}

runtime.resumeFileWriteBytesErr(ctx, susp23[0], { kindCode: 42, msg: "nope" });

const more23 = runtime.schedStep(ctx, 10);
if (more23.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileWriteBytesErr, got ${more23.length}`);
}

const out23 = runtime.pollTask(ctx, t23);
if (out23?.tag !== "thrown") {
  throw new Error(`expected thrown for task t23, got ${out23?.tag}`);
}
const s23 = runtime.unboxString(ctx, out23.val);
if (s23 !== "42 nope") {
  throw new Error(`expected '42 nope' for task t23, got '${s23}'`);
}
maybeDispose(out23.val);

// --- def 24: typed per-op WIT (file-mk-temp-dir) ---
const t24 = runtime.startTask(ctx, 24n, []);
const susp24 = runtime.schedStep(ctx, 10);
if (susp24.length !== 1) {
  throw new Error(`expected 1 suspension for task t24, got ${susp24.length}`);
}

const req24 = runtime.suspensionRequest(ctx, susp24[0]);
if (req24.tag !== "file-mk-temp-dir") {
  throw new Error(`expected file-mk-temp-dir request, got ${req24.tag}`);
}
if (req24.val.prefix !== "flix") {
  throw new Error(`unexpected file-mk-temp-dir request: prefix=${req24.val.prefix}`);
}

runtime.resumeFileMkTempDirOk(ctx, susp24[0], "tmp/flix-123");

const more24 = runtime.schedStep(ctx, 10);
if (more24.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileMkTempDirOk, got ${more24.length}`);
}

const out24 = runtime.pollTask(ctx, t24);
if (out24?.tag !== "ok") {
  throw new Error(`expected ok for task t24, got ${out24?.tag}`);
}
const s24 = runtime.unboxString(ctx, out24.val);
if (s24 !== "tmp/flix-123") {
  throw new Error(`expected 'tmp/flix-123' for task t24, got '${s24}'`);
}
maybeDispose(out24.val);

// --- def 25: typed per-op WIT (process-exec ok) ---
const t25 = runtime.startTask(ctx, 25n, []);
const susp25 = runtime.schedStep(ctx, 10);
if (susp25.length !== 1) {
  throw new Error(`expected 1 suspension for task t25, got ${susp25.length}`);
}

const req25 = runtime.suspensionRequest(ctx, susp25[0]);
if (req25.tag !== "process-exec") {
  throw new Error(`expected process-exec request, got ${req25.tag}`);
}
if (req25.val.argv.length !== 2 || req25.val.argv[0] !== "echo" || req25.val.argv[1] !== "hello") {
  throw new Error(`unexpected process-exec argv: ${req25.val.argv}`);
}
if (req25.val.cwd !== "tmp") {
  throw new Error(`unexpected process-exec cwd: ${req25.val.cwd}`);
}
if (
  req25.val.env.length !== 1 ||
  req25.val.env[0].key !== "FOO" ||
  req25.val.env[0].value !== "BAR"
) {
  throw new Error(`unexpected process-exec env: ${JSON.stringify(req25.val.env)}`);
}

runtime.resumeProcessExecOk(ctx, susp25[0], 99n);

const more25 = runtime.schedStep(ctx, 10);
if (more25.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessExecOk, got ${more25.length}`);
}

const out25 = runtime.pollTask(ctx, t25);
if (out25?.tag !== "ok") {
  throw new Error(`expected ok for task t25, got ${out25?.tag}`);
}
const s25 = runtime.unboxString(ctx, out25.val);
if (s25 !== "proc=99") {
  throw new Error(`expected 'proc=99' for task t25, got '${s25}'`);
}
maybeDispose(out25.val);

// --- def 26: typed per-op WIT (process-exec err) ---
const t26 = runtime.startTask(ctx, 26n, []);
const susp26 = runtime.schedStep(ctx, 10);
if (susp26.length !== 1) {
  throw new Error(`expected 1 suspension for task t26, got ${susp26.length}`);
}

const req26 = runtime.suspensionRequest(ctx, susp26[0]);
if (req26.tag !== "process-exec") {
  throw new Error(`expected process-exec request for task t26, got ${req26.tag}`);
}

runtime.resumeProcessExecErr(ctx, susp26[0], { kindCode: 42, msg: "nope" });

const more26 = runtime.schedStep(ctx, 10);
if (more26.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessExecErr, got ${more26.length}`);
}

const out26 = runtime.pollTask(ctx, t26);
if (out26?.tag !== "thrown") {
  throw new Error(`expected thrown for task t26, got ${out26?.tag}`);
}
const s26 = runtime.unboxString(ctx, out26.val);
if (s26 !== "42 nope") {
  throw new Error(`expected '42 nope' for task t26, got '${s26}'`);
}
maybeDispose(out26.val);

// --- def 27: typed per-op WIT (process-pid) ---
const t27 = runtime.startTask(ctx, 27n, []);
const susp27 = runtime.schedStep(ctx, 10);
if (susp27.length !== 1) {
  throw new Error(`expected 1 suspension for task t27, got ${susp27.length}`);
}

const req27 = runtime.suspensionRequest(ctx, susp27[0]);
if (req27.tag !== "process-pid") {
  throw new Error(`expected process-pid request, got ${req27.tag}`);
}
if (req27.val.processId !== 77n) {
  throw new Error(`unexpected process-pid request: processId=${req27.val.processId}`);
}

runtime.resumeProcessPidOk(ctx, susp27[0], 1234n);

const more27 = runtime.schedStep(ctx, 10);
if (more27.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessPidOk, got ${more27.length}`);
}

const out27 = runtime.pollTask(ctx, t27);
if (out27?.tag !== "ok") {
  throw new Error(`expected ok for task t27, got ${out27?.tag}`);
}
const s27 = runtime.unboxString(ctx, out27.val);
if (s27 !== "pid=1234") {
  throw new Error(`expected 'pid=1234' for task t27, got '${s27}'`);
}
maybeDispose(out27.val);

// --- def 28: typed per-op WIT (process-wait-for) ---
const t28 = runtime.startTask(ctx, 28n, []);
const susp28 = runtime.schedStep(ctx, 10);
if (susp28.length !== 1) {
  throw new Error(`expected 1 suspension for task t28, got ${susp28.length}`);
}

const req28 = runtime.suspensionRequest(ctx, susp28[0]);
if (req28.tag !== "process-wait-for") {
  throw new Error(`expected process-wait-for request, got ${req28.tag}`);
}
if (req28.val.processId !== 77n) {
  throw new Error(`unexpected process-wait-for request: processId=${req28.val.processId}`);
}

runtime.resumeProcessWaitForOk(ctx, susp28[0], 0);

const more28 = runtime.schedStep(ctx, 10);
if (more28.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessWaitForOk, got ${more28.length}`);
}

const out28 = runtime.pollTask(ctx, t28);
if (out28?.tag !== "ok") {
  throw new Error(`expected ok for task t28, got ${out28?.tag}`);
}
const s28 = runtime.unboxString(ctx, out28.val);
if (s28 !== "wait=0") {
  throw new Error(`expected 'wait=0' for task t28, got '${s28}'`);
}
maybeDispose(out28.val);

// --- def 29: typed per-op WIT (process-wait-for-timeout) ---
const t29 = runtime.startTask(ctx, 29n, []);
const susp29 = runtime.schedStep(ctx, 10);
if (susp29.length !== 1) {
  throw new Error(`expected 1 suspension for task t29, got ${susp29.length}`);
}

const req29 = runtime.suspensionRequest(ctx, susp29[0]);
if (req29.tag !== "process-wait-for-timeout") {
  throw new Error(`expected process-wait-for-timeout request, got ${req29.tag}`);
}
if (req29.val.processId !== 77n || req29.val.timeoutMs !== 1000n) {
  throw new Error(
    `unexpected process-wait-for-timeout request: processId=${req29.val.processId} timeoutMs=${req29.val.timeoutMs}`,
  );
}

runtime.resumeProcessWaitForTimeoutOk(ctx, susp29[0], true);

const more29 = runtime.schedStep(ctx, 10);
if (more29.length !== 0) {
  throw new Error(
    `expected no further suspensions after resumeProcessWaitForTimeoutOk, got ${more29.length}`,
  );
}

const out29 = runtime.pollTask(ctx, t29);
if (out29?.tag !== "ok") {
  throw new Error(`expected ok for task t29, got ${out29?.tag}`);
}
const s29 = runtime.unboxString(ctx, out29.val);
if (s29 !== "finished=true") {
  throw new Error(`expected 'finished=true' for task t29, got '${s29}'`);
}
maybeDispose(out29.val);

// --- def 30: typed per-op WIT (process-stdin-write) ---
const t30 = runtime.startTask(ctx, 30n, []);
const susp30 = runtime.schedStep(ctx, 10);
if (susp30.length !== 1) {
  throw new Error(`expected 1 suspension for task t30, got ${susp30.length}`);
}

const req30 = runtime.suspensionRequest(ctx, susp30[0]);
if (req30.tag !== "process-stdin-write") {
  throw new Error(`expected process-stdin-write request, got ${req30.tag}`);
}
if (req30.val.processId !== 77n) {
  throw new Error(`unexpected process-stdin-write request: processId=${req30.val.processId}`);
}
if (
  req30.val.bytes.length !== 3 ||
  req30.val.bytes[0] !== 1 ||
  req30.val.bytes[1] !== 2 ||
  req30.val.bytes[2] !== 3
) {
  throw new Error(`unexpected process-stdin-write bytes: ${req30.val.bytes}`);
}

runtime.resumeProcessStdinWriteOk(ctx, susp30[0]);

const more30 = runtime.schedStep(ctx, 10);
if (more30.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessStdinWriteOk, got ${more30.length}`);
}

const out30 = runtime.pollTask(ctx, t30);
if (out30?.tag !== "ok") {
  throw new Error(`expected ok for task t30, got ${out30?.tag}`);
}
const s30 = runtime.unboxString(ctx, out30.val);
if (s30 !== "stdin-wrote=3") {
  throw new Error(`expected 'stdin-wrote=3' for task t30, got '${s30}'`);
}
maybeDispose(out30.val);

// --- def 31: typed per-op WIT (process-stdout-read) ---
const t31 = runtime.startTask(ctx, 31n, []);
const susp31 = runtime.schedStep(ctx, 10);
if (susp31.length !== 1) {
  throw new Error(`expected 1 suspension for task t31, got ${susp31.length}`);
}

const req31 = runtime.suspensionRequest(ctx, susp31[0]);
if (req31.tag !== "process-stdout-read") {
  throw new Error(`expected process-stdout-read request, got ${req31.tag}`);
}
if (req31.val.processId !== 77n || req31.val.maxBytes !== 4) {
  throw new Error(
    `unexpected process-stdout-read request: processId=${req31.val.processId} maxBytes=${req31.val.maxBytes}`,
  );
}

runtime.resumeProcessStdoutReadOk(ctx, susp31[0], new Uint8Array([1, 2, 3]));

const more31 = runtime.schedStep(ctx, 10);
if (more31.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessStdoutReadOk, got ${more31.length}`);
}

const out31 = runtime.pollTask(ctx, t31);
if (out31?.tag !== "ok") {
  throw new Error(`expected ok for task t31, got ${out31?.tag}`);
}
const s31 = runtime.unboxString(ctx, out31.val);
if (s31 !== "stdout=3 first=1") {
  throw new Error(`expected 'stdout=3 first=1' for task t31, got '${s31}'`);
}
maybeDispose(out31.val);

// --- def 32: typed per-op WIT (process-stderr-read) ---
const t32 = runtime.startTask(ctx, 32n, []);
const susp32 = runtime.schedStep(ctx, 10);
if (susp32.length !== 1) {
  throw new Error(`expected 1 suspension for task t32, got ${susp32.length}`);
}

const req32 = runtime.suspensionRequest(ctx, susp32[0]);
if (req32.tag !== "process-stderr-read") {
  throw new Error(`expected process-stderr-read request, got ${req32.tag}`);
}
if (req32.val.processId !== 77n || req32.val.maxBytes !== 4) {
  throw new Error(
    `unexpected process-stderr-read request: processId=${req32.val.processId} maxBytes=${req32.val.maxBytes}`,
  );
}

runtime.resumeProcessStderrReadOk(ctx, susp32[0], new Uint8Array([4, 5]));

const more32 = runtime.schedStep(ctx, 10);
if (more32.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessStderrReadOk, got ${more32.length}`);
}

const out32 = runtime.pollTask(ctx, t32);
if (out32?.tag !== "ok") {
  throw new Error(`expected ok for task t32, got ${out32?.tag}`);
}
const s32 = runtime.unboxString(ctx, out32.val);
if (s32 !== "stderr=2 first=4") {
  throw new Error(`expected 'stderr=2 first=4' for task t32, got '${s32}'`);
}
maybeDispose(out32.val);

// --- def 33: typed per-op WIT (process-release) ---
const t33 = runtime.startTask(ctx, 33n, []);
const susp33 = runtime.schedStep(ctx, 10);
if (susp33.length !== 1) {
  throw new Error(`expected 1 suspension for task t33, got ${susp33.length}`);
}

const req33 = runtime.suspensionRequest(ctx, susp33[0]);
if (req33.tag !== "process-release") {
  throw new Error(`expected process-release request, got ${req33.tag}`);
}
if (req33.val.processId !== 77n) {
  throw new Error(`unexpected process-release request: processId=${req33.val.processId}`);
}

runtime.resumeProcessReleaseOk(ctx, susp33[0]);

const more33 = runtime.schedStep(ctx, 10);
if (more33.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessReleaseOk, got ${more33.length}`);
}

const out33 = runtime.pollTask(ctx, t33);
if (out33?.tag !== "ok") {
  throw new Error(`expected ok for task t33, got ${out33?.tag}`);
}
const s33 = runtime.unboxString(ctx, out33.val);
if (s33 !== "released") {
  throw new Error(`expected 'released' for task t33, got '${s33}'`);
}
maybeDispose(out33.val);

// --- def 34: typed per-op WIT (file-is-directory) ---
const t34 = runtime.startTask(ctx, 34n, []);
const susp34 = runtime.schedStep(ctx, 10);
if (susp34.length !== 1) {
  throw new Error(`expected 1 suspension for task t34, got ${susp34.length}`);
}

const req34 = runtime.suspensionRequest(ctx, susp34[0]);
if (req34.tag !== "file-is-directory") {
  throw new Error(`expected file-is-directory request, got ${req34.tag}`);
}
if (req34.val.path !== "fixtures") {
  throw new Error(`unexpected file-is-directory request: path=${req34.val.path}`);
}

runtime.resumeFileIsDirectoryOk(ctx, susp34[0], true);

const more34 = runtime.schedStep(ctx, 10);
if (more34.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsDirectoryOk, got ${more34.length}`);
}

const out34 = runtime.pollTask(ctx, t34);
if (out34?.tag !== "ok") {
  throw new Error(`expected ok for task t34, got ${out34?.tag}`);
}
const s34 = runtime.unboxString(ctx, out34.val);
if (s34 !== "is-directory=true") {
  throw new Error(`expected 'is-directory=true' for task t34, got '${s34}'`);
}
maybeDispose(out34.val);

// --- def 35: typed per-op WIT (file-is-regular-file) ---
const t35 = runtime.startTask(ctx, 35n, []);
const susp35 = runtime.schedStep(ctx, 10);
if (susp35.length !== 1) {
  throw new Error(`expected 1 suspension for task t35, got ${susp35.length}`);
}

const req35 = runtime.suspensionRequest(ctx, susp35[0]);
if (req35.tag !== "file-is-regular-file") {
  throw new Error(`expected file-is-regular-file request, got ${req35.tag}`);
}
if (req35.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-is-regular-file request: path=${req35.val.path}`);
}

runtime.resumeFileIsRegularFileOk(ctx, susp35[0], true);

const more35 = runtime.schedStep(ctx, 10);
if (more35.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsRegularFileOk, got ${more35.length}`);
}

const out35 = runtime.pollTask(ctx, t35);
if (out35?.tag !== "ok") {
  throw new Error(`expected ok for task t35, got ${out35?.tag}`);
}
const s35 = runtime.unboxString(ctx, out35.val);
if (s35 !== "is-regular-file=true") {
  throw new Error(`expected 'is-regular-file=true' for task t35, got '${s35}'`);
}
maybeDispose(out35.val);

// --- def 36: typed per-op WIT (file-is-readable) ---
const t36 = runtime.startTask(ctx, 36n, []);
const susp36 = runtime.schedStep(ctx, 10);
if (susp36.length !== 1) {
  throw new Error(`expected 1 suspension for task t36, got ${susp36.length}`);
}

const req36 = runtime.suspensionRequest(ctx, susp36[0]);
if (req36.tag !== "file-is-readable") {
  throw new Error(`expected file-is-readable request, got ${req36.tag}`);
}
if (req36.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-is-readable request: path=${req36.val.path}`);
}

runtime.resumeFileIsReadableOk(ctx, susp36[0], true);

const more36 = runtime.schedStep(ctx, 10);
if (more36.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsReadableOk, got ${more36.length}`);
}

const out36 = runtime.pollTask(ctx, t36);
if (out36?.tag !== "ok") {
  throw new Error(`expected ok for task t36, got ${out36?.tag}`);
}
const s36 = runtime.unboxString(ctx, out36.val);
if (s36 !== "is-readable=true") {
  throw new Error(`expected 'is-readable=true' for task t36, got '${s36}'`);
}
maybeDispose(out36.val);

// --- def 37: typed per-op WIT (file-is-symbolic-link) ---
const t37 = runtime.startTask(ctx, 37n, []);
const susp37 = runtime.schedStep(ctx, 10);
if (susp37.length !== 1) {
  throw new Error(`expected 1 suspension for task t37, got ${susp37.length}`);
}

const req37 = runtime.suspensionRequest(ctx, susp37[0]);
if (req37.tag !== "file-is-symbolic-link") {
  throw new Error(`expected file-is-symbolic-link request, got ${req37.tag}`);
}
if (req37.val.path !== "fixtures/link.txt") {
  throw new Error(`unexpected file-is-symbolic-link request: path=${req37.val.path}`);
}

runtime.resumeFileIsSymbolicLinkOk(ctx, susp37[0], true);

const more37 = runtime.schedStep(ctx, 10);
if (more37.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsSymbolicLinkOk, got ${more37.length}`);
}

const out37 = runtime.pollTask(ctx, t37);
if (out37?.tag !== "ok") {
  throw new Error(`expected ok for task t37, got ${out37?.tag}`);
}
const s37 = runtime.unboxString(ctx, out37.val);
if (s37 !== "is-symbolic-link=true") {
  throw new Error(`expected 'is-symbolic-link=true' for task t37, got '${s37}'`);
}
maybeDispose(out37.val);

// --- def 38: typed per-op WIT (file-is-writable) ---
const t38 = runtime.startTask(ctx, 38n, []);
const susp38 = runtime.schedStep(ctx, 10);
if (susp38.length !== 1) {
  throw new Error(`expected 1 suspension for task t38, got ${susp38.length}`);
}

const req38 = runtime.suspensionRequest(ctx, susp38[0]);
if (req38.tag !== "file-is-writable") {
  throw new Error(`expected file-is-writable request, got ${req38.tag}`);
}
if (req38.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-is-writable request: path=${req38.val.path}`);
}

runtime.resumeFileIsWritableOk(ctx, susp38[0], true);

const more38 = runtime.schedStep(ctx, 10);
if (more38.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsWritableOk, got ${more38.length}`);
}

const out38 = runtime.pollTask(ctx, t38);
if (out38?.tag !== "ok") {
  throw new Error(`expected ok for task t38, got ${out38?.tag}`);
}
const s38 = runtime.unboxString(ctx, out38.val);
if (s38 !== "is-writable=true") {
  throw new Error(`expected 'is-writable=true' for task t38, got '${s38}'`);
}
maybeDispose(out38.val);

// --- def 39: typed per-op WIT (file-is-executable) ---
const t39 = runtime.startTask(ctx, 39n, []);
const susp39 = runtime.schedStep(ctx, 10);
if (susp39.length !== 1) {
  throw new Error(`expected 1 suspension for task t39, got ${susp39.length}`);
}

const req39 = runtime.suspensionRequest(ctx, susp39[0]);
if (req39.tag !== "file-is-executable") {
  throw new Error(`expected file-is-executable request, got ${req39.tag}`);
}
if (req39.val.path !== "fixtures/bin") {
  throw new Error(`unexpected file-is-executable request: path=${req39.val.path}`);
}

runtime.resumeFileIsExecutableOk(ctx, susp39[0], true);

const more39 = runtime.schedStep(ctx, 10);
if (more39.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileIsExecutableOk, got ${more39.length}`);
}

const out39 = runtime.pollTask(ctx, t39);
if (out39?.tag !== "ok") {
  throw new Error(`expected ok for task t39, got ${out39?.tag}`);
}
const s39 = runtime.unboxString(ctx, out39.val);
if (s39 !== "is-executable=true") {
  throw new Error(`expected 'is-executable=true' for task t39, got '${s39}'`);
}
maybeDispose(out39.val);

// --- def 40: typed per-op WIT (file-access-time) ---
const t40 = runtime.startTask(ctx, 40n, []);
const susp40 = runtime.schedStep(ctx, 10);
if (susp40.length !== 1) {
  throw new Error(`expected 1 suspension for task t40, got ${susp40.length}`);
}

const req40 = runtime.suspensionRequest(ctx, susp40[0]);
if (req40.tag !== "file-access-time") {
  throw new Error(`expected file-access-time request, got ${req40.tag}`);
}
if (req40.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-access-time request: path=${req40.val.path}`);
}

runtime.resumeFileAccessTimeOk(ctx, susp40[0], 111n);

const more40 = runtime.schedStep(ctx, 10);
if (more40.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileAccessTimeOk, got ${more40.length}`);
}

const out40 = runtime.pollTask(ctx, t40);
if (out40?.tag !== "ok") {
  throw new Error(`expected ok for task t40, got ${out40?.tag}`);
}
const s40 = runtime.unboxString(ctx, out40.val);
if (s40 !== "access-ms=111") {
  throw new Error(`expected 'access-ms=111' for task t40, got '${s40}'`);
}
maybeDispose(out40.val);

// --- def 41: typed per-op WIT (file-creation-time) ---
const t41 = runtime.startTask(ctx, 41n, []);
const susp41 = runtime.schedStep(ctx, 10);
if (susp41.length !== 1) {
  throw new Error(`expected 1 suspension for task t41, got ${susp41.length}`);
}

const req41 = runtime.suspensionRequest(ctx, susp41[0]);
if (req41.tag !== "file-creation-time") {
  throw new Error(`expected file-creation-time request, got ${req41.tag}`);
}
if (req41.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-creation-time request: path=${req41.val.path}`);
}

runtime.resumeFileCreationTimeOk(ctx, susp41[0], 222n);

const more41 = runtime.schedStep(ctx, 10);
if (more41.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileCreationTimeOk, got ${more41.length}`);
}

const out41 = runtime.pollTask(ctx, t41);
if (out41?.tag !== "ok") {
  throw new Error(`expected ok for task t41, got ${out41?.tag}`);
}
const s41 = runtime.unboxString(ctx, out41.val);
if (s41 !== "creation-ms=222") {
  throw new Error(`expected 'creation-ms=222' for task t41, got '${s41}'`);
}
maybeDispose(out41.val);

// --- def 42: typed per-op WIT (file-modification-time) ---
const t42 = runtime.startTask(ctx, 42n, []);
const susp42 = runtime.schedStep(ctx, 10);
if (susp42.length !== 1) {
  throw new Error(`expected 1 suspension for task t42, got ${susp42.length}`);
}

const req42 = runtime.suspensionRequest(ctx, susp42[0]);
if (req42.tag !== "file-modification-time") {
  throw new Error(`expected file-modification-time request, got ${req42.tag}`);
}
if (req42.val.path !== "fixtures/hello.txt") {
  throw new Error(`unexpected file-modification-time request: path=${req42.val.path}`);
}

runtime.resumeFileModificationTimeOk(ctx, susp42[0], 333n);

const more42 = runtime.schedStep(ctx, 10);
if (more42.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileModificationTimeOk, got ${more42.length}`);
}

const out42 = runtime.pollTask(ctx, t42);
if (out42?.tag !== "ok") {
  throw new Error(`expected ok for task t42, got ${out42?.tag}`);
}
const s42 = runtime.unboxString(ctx, out42.val);
if (s42 !== "mod-ms=333") {
  throw new Error(`expected 'mod-ms=333' for task t42, got '${s42}'`);
}
maybeDispose(out42.val);

// --- def 43: typed per-op WIT (file-write-bytes ok) ---
const t43 = runtime.startTask(ctx, 43n, []);
const susp43 = runtime.schedStep(ctx, 10);
if (susp43.length !== 1) {
  throw new Error(`expected 1 suspension for task t43, got ${susp43.length}`);
}

const req43 = runtime.suspensionRequest(ctx, susp43[0]);
if (req43.tag !== "file-write-bytes") {
  throw new Error(`expected file-write-bytes request, got ${req43.tag}`);
}

runtime.resumeFileWriteBytesOk(ctx, susp43[0]);

const more43 = runtime.schedStep(ctx, 10);
if (more43.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileWriteBytesOk, got ${more43.length}`);
}

const out43 = runtime.pollTask(ctx, t43);
if (out43?.tag !== "ok") {
  throw new Error(`expected ok for task t43, got ${out43?.tag}`);
}
const s43 = runtime.unboxString(ctx, out43.val);
if (s43 !== "write-bytes-ok") {
  throw new Error(`expected 'write-bytes-ok' for task t43, got '${s43}'`);
}
maybeDispose(out43.val);

// --- def 44: typed per-op WIT (file-append ok) ---
const t44 = runtime.startTask(ctx, 44n, []);
const susp44 = runtime.schedStep(ctx, 10);
if (susp44.length !== 1) {
  throw new Error(`expected 1 suspension for task t44, got ${susp44.length}`);
}

const req44 = runtime.suspensionRequest(ctx, susp44[0]);
if (req44.tag !== "file-append") {
  throw new Error(`expected file-append request, got ${req44.tag}`);
}
if (req44.val.path !== "out/append.txt" || req44.val.data !== "hello") {
  throw new Error(`unexpected file-append request: path=${req44.val.path} data=${req44.val.data}`);
}

runtime.resumeFileAppendOk(ctx, susp44[0]);

const more44 = runtime.schedStep(ctx, 10);
if (more44.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileAppendOk, got ${more44.length}`);
}

const out44 = runtime.pollTask(ctx, t44);
if (out44?.tag !== "ok") {
  throw new Error(`expected ok for task t44, got ${out44?.tag}`);
}
const s44 = runtime.unboxString(ctx, out44.val);
if (s44 !== "append-ok") {
  throw new Error(`expected 'append-ok' for task t44, got '${s44}'`);
}
maybeDispose(out44.val);

// --- def 45: typed per-op WIT (file-append-bytes ok) ---
const t45 = runtime.startTask(ctx, 45n, []);
const susp45 = runtime.schedStep(ctx, 10);
if (susp45.length !== 1) {
  throw new Error(`expected 1 suspension for task t45, got ${susp45.length}`);
}

const req45 = runtime.suspensionRequest(ctx, susp45[0]);
if (req45.tag !== "file-append-bytes") {
  throw new Error(`expected file-append-bytes request, got ${req45.tag}`);
}
if (req45.val.path !== "out/append.bin") {
  throw new Error(`unexpected file-append-bytes request: path=${req45.val.path}`);
}
if (
  req45.val.bytes.length !== 3 ||
  req45.val.bytes[0] !== 4 ||
  req45.val.bytes[1] !== 5 ||
  req45.val.bytes[2] !== 6
) {
  throw new Error(`unexpected file-append-bytes bytes: ${req45.val.bytes}`);
}

runtime.resumeFileAppendBytesOk(ctx, susp45[0]);

const more45 = runtime.schedStep(ctx, 10);
if (more45.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileAppendBytesOk, got ${more45.length}`);
}

const out45 = runtime.pollTask(ctx, t45);
if (out45?.tag !== "ok") {
  throw new Error(`expected ok for task t45, got ${out45?.tag}`);
}
const s45 = runtime.unboxString(ctx, out45.val);
if (s45 !== "append-bytes-ok") {
  throw new Error(`expected 'append-bytes-ok' for task t45, got '${s45}'`);
}
maybeDispose(out45.val);

// --- def 46: typed per-op WIT (file-truncate ok) ---
const t46 = runtime.startTask(ctx, 46n, []);
const susp46 = runtime.schedStep(ctx, 10);
if (susp46.length !== 1) {
  throw new Error(`expected 1 suspension for task t46, got ${susp46.length}`);
}

const req46 = runtime.suspensionRequest(ctx, susp46[0]);
if (req46.tag !== "file-truncate") {
  throw new Error(`expected file-truncate request, got ${req46.tag}`);
}
if (req46.val.path !== "out/trunc.txt") {
  throw new Error(`unexpected file-truncate request: path=${req46.val.path}`);
}

runtime.resumeFileTruncateOk(ctx, susp46[0]);

const more46 = runtime.schedStep(ctx, 10);
if (more46.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileTruncateOk, got ${more46.length}`);
}

const out46 = runtime.pollTask(ctx, t46);
if (out46?.tag !== "ok") {
  throw new Error(`expected ok for task t46, got ${out46?.tag}`);
}
const s46 = runtime.unboxString(ctx, out46.val);
if (s46 !== "truncate-ok") {
  throw new Error(`expected 'truncate-ok' for task t46, got '${s46}'`);
}
maybeDispose(out46.val);

// --- def 47: typed per-op WIT (file-mkdir ok) ---
const t47 = runtime.startTask(ctx, 47n, []);
const susp47 = runtime.schedStep(ctx, 10);
if (susp47.length !== 1) {
  throw new Error(`expected 1 suspension for task t47, got ${susp47.length}`);
}

const req47 = runtime.suspensionRequest(ctx, susp47[0]);
if (req47.tag !== "file-mkdir") {
  throw new Error(`expected file-mkdir request, got ${req47.tag}`);
}
if (req47.val.path !== "out/dir") {
  throw new Error(`unexpected file-mkdir request: path=${req47.val.path}`);
}

runtime.resumeFileMkdirOk(ctx, susp47[0]);

const more47 = runtime.schedStep(ctx, 10);
if (more47.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileMkdirOk, got ${more47.length}`);
}

const out47 = runtime.pollTask(ctx, t47);
if (out47?.tag !== "ok") {
  throw new Error(`expected ok for task t47, got ${out47?.tag}`);
}
const s47 = runtime.unboxString(ctx, out47.val);
if (s47 !== "mkdir-ok") {
  throw new Error(`expected 'mkdir-ok' for task t47, got '${s47}'`);
}
maybeDispose(out47.val);

// --- def 48: typed per-op WIT (file-mkdirs ok) ---
const t48 = runtime.startTask(ctx, 48n, []);
const susp48 = runtime.schedStep(ctx, 10);
if (susp48.length !== 1) {
  throw new Error(`expected 1 suspension for task t48, got ${susp48.length}`);
}

const req48 = runtime.suspensionRequest(ctx, susp48[0]);
if (req48.tag !== "file-mkdirs") {
  throw new Error(`expected file-mkdirs request, got ${req48.tag}`);
}
if (req48.val.path !== "out/dir/nested") {
  throw new Error(`unexpected file-mkdirs request: path=${req48.val.path}`);
}

runtime.resumeFileMkdirsOk(ctx, susp48[0]);

const more48 = runtime.schedStep(ctx, 10);
if (more48.length !== 0) {
  throw new Error(`expected no further suspensions after resumeFileMkdirsOk, got ${more48.length}`);
}

const out48 = runtime.pollTask(ctx, t48);
if (out48?.tag !== "ok") {
  throw new Error(`expected ok for task t48, got ${out48?.tag}`);
}
const s48 = runtime.unboxString(ctx, out48.val);
if (s48 !== "mkdirs-ok") {
  throw new Error(`expected 'mkdirs-ok' for task t48, got '${s48}'`);
}
maybeDispose(out48.val);

// --- def 49: typed per-op WIT (process-exit-value) ---
const t49 = runtime.startTask(ctx, 49n, []);
const susp49 = runtime.schedStep(ctx, 10);
if (susp49.length !== 1) {
  throw new Error(`expected 1 suspension for task t49, got ${susp49.length}`);
}

const req49 = runtime.suspensionRequest(ctx, susp49[0]);
if (req49.tag !== "process-exit-value") {
  throw new Error(`expected process-exit-value request, got ${req49.tag}`);
}

runtime.resumeProcessExitValueOk(ctx, susp49[0], 7);

const more49 = runtime.schedStep(ctx, 10);
if (more49.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessExitValueOk, got ${more49.length}`);
}

const out49 = runtime.pollTask(ctx, t49);
if (out49?.tag !== "ok") {
  throw new Error(`expected ok for task t49, got ${out49?.tag}`);
}
const s49 = runtime.unboxString(ctx, out49.val);
if (s49 !== "exit=7") {
  throw new Error(`expected 'exit=7' for task t49, got '${s49}'`);
}
maybeDispose(out49.val);

// --- def 50: typed per-op WIT (process-is-alive) ---
const t50 = runtime.startTask(ctx, 50n, []);
const susp50 = runtime.schedStep(ctx, 10);
if (susp50.length !== 1) {
  throw new Error(`expected 1 suspension for task t50, got ${susp50.length}`);
}

const req50 = runtime.suspensionRequest(ctx, susp50[0]);
if (req50.tag !== "process-is-alive") {
  throw new Error(`expected process-is-alive request, got ${req50.tag}`);
}

runtime.resumeProcessIsAliveOk(ctx, susp50[0], true);

const more50 = runtime.schedStep(ctx, 10);
if (more50.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessIsAliveOk, got ${more50.length}`);
}

const out50 = runtime.pollTask(ctx, t50);
if (out50?.tag !== "ok") {
  throw new Error(`expected ok for task t50, got ${out50?.tag}`);
}
const s50 = runtime.unboxString(ctx, out50.val);
if (s50 !== "alive=true") {
  throw new Error(`expected 'alive=true' for task t50, got '${s50}'`);
}
maybeDispose(out50.val);

// --- def 51: typed per-op WIT (process-stop) ---
const t51 = runtime.startTask(ctx, 51n, []);
const susp51 = runtime.schedStep(ctx, 10);
if (susp51.length !== 1) {
  throw new Error(`expected 1 suspension for task t51, got ${susp51.length}`);
}

const req51 = runtime.suspensionRequest(ctx, susp51[0]);
if (req51.tag !== "process-stop") {
  throw new Error(`expected process-stop request, got ${req51.tag}`);
}

runtime.resumeProcessStopOk(ctx, susp51[0]);

const more51 = runtime.schedStep(ctx, 10);
if (more51.length !== 0) {
  throw new Error(`expected no further suspensions after resumeProcessStopOk, got ${more51.length}`);
}

const out51 = runtime.pollTask(ctx, t51);
if (out51?.tag !== "ok") {
  throw new Error(`expected ok for task t51, got ${out51?.tag}`);
}
const s51 = runtime.unboxString(ctx, out51.val);
if (s51 !== "stopped") {
  throw new Error(`expected 'stopped' for task t51, got '${s51}'`);
}
maybeDispose(out51.val);

// --- def 2: start two tasks; ensure multiple in-flight suspensions ---
const t1 = runtime.startTask(ctx, 2n, []);
const t2 = runtime.startTask(ctx, 2n, []);

const suspensions = runtime.schedStep(ctx, 10);
if (suspensions.length !== 2) {
  throw new Error(`expected 2 suspensions, got ${suspensions.length}`);
}

for (const s of suspensions) {
  const info = runtime.suspensionPeek(ctx, s);
  if (info.effId !== 10n || info.opId !== 20n) {
    throw new Error(`unexpected suspension-info: effId=${info.effId} opId=${info.opId}`);
  }
}

if (runtime.pollTask(ctx, t1) != null) {
  throw new Error("expected task t1 incomplete before resumption");
}
if (runtime.pollTask(ctx, t2) != null) {
  throw new Error("expected task t2 incomplete before resumption");
}

const resumeIn1 = runtime.boxString(ctx, "resumed ok #1");
runtime.resumeOk(ctx, suspensions[0], resumeIn1);
maybeDispose(resumeIn1);

const resumeIn2 = runtime.boxString(ctx, "resumed ok #2");
runtime.resumeOk(ctx, suspensions[1], resumeIn2);
maybeDispose(resumeIn2);

const more = runtime.schedStep(ctx, 10);
if (more.length !== 0) {
  throw new Error(`expected no further suspensions after resumption, got ${more.length}`);
}

const out1 = runtime.pollTask(ctx, t1);
if (out1?.tag !== "ok") {
  throw new Error(`expected ok for task t1, got ${out1?.tag}`);
}
const resumed1 = runtime.unboxString(ctx, out1.val);
if (resumed1 !== "resumed ok #1") {
  throw new Error(`expected 'resumed ok #1', got '${resumed1}'`);
}
maybeDispose(out1.val);

const out2 = runtime.pollTask(ctx, t2);
if (out2?.tag !== "ok") {
  throw new Error(`expected ok for task t2, got ${out2?.tag}`);
}
const resumed2 = runtime.unboxString(ctx, out2.val);
if (resumed2 !== "resumed ok #2") {
  throw new Error(`expected 'resumed ok #2', got '${resumed2}'`);
}
maybeDispose(out2.val);

// --- def 2: suspended + resume-throw ---
const t3 = runtime.startTask(ctx, 2n, []);
const suspensions2 = runtime.schedStep(ctx, 10);
if (suspensions2.length !== 1) {
  throw new Error(`expected 1 suspension for task t3, got ${suspensions2.length}`);
}

const exnIn = runtime.boxString(ctx, "resumed threw");
runtime.resumeThrow(ctx, suspensions2[0], exnIn);
maybeDispose(exnIn);

const more2 = runtime.schedStep(ctx, 10);
if (more2.length !== 0) {
  throw new Error(`expected no further suspensions after resumeThrow, got ${more2.length}`);
}

const out3 = runtime.pollTask(ctx, t3);
if (out3?.tag !== "thrown") {
  throw new Error(`expected thrown for task t3, got ${out3?.tag}`);
}
const thrown = runtime.unboxString(ctx, out3.val);
if (thrown !== "resumed threw") {
  throw new Error(`expected 'resumed threw', got '${thrown}'`);
}
maybeDispose(out3.val);

// --- def 3: thrown ---
const execThrown2 = runtime.invoke(ctx, 3n, []);
if (execThrown2.tag !== "thrown") {
  throw new Error(`expected thrown, got ${execThrown2.tag}`);
}

const msg = runtime.unboxString(ctx, execThrown2.val);
if (msg !== "thrown from flix-smoke") {
  throw new Error(`unexpected thrown payload: '${msg}'`);
}

console.log(`js smoke OK: add + typed ops + multi-suspension scheduling + throw all passed (sum=${sum})`);

// Best-effort cleanup of lifted resource handles.
maybeDispose(execThrown2.val);
maybeDispose(ctx);
