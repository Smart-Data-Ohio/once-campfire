import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { supervise } from "./supervisor.mjs";

const quietLogger = { error() {} };

test("a child exit stops its peer, forces a bounded kill, and fails the runtime", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "huddle-supervisor-"));
  const marker = path.join(directory, "term-seen");
  const code = await supervise([
    { name: "exiter", command: process.execPath, args: ["-e", "setTimeout(() => process.exit(0), 40)"] },
    {
      name: "stubborn peer",
      command: process.execPath,
      args: ["-e", "process.on('SIGTERM',()=>require('fs').writeFileSync(process.argv[1],'yes'));setInterval(()=>{},1000)", marker],
    },
  ], { graceMs: 100, signalSource: new EventEmitter(), logger: quietLogger });

  assert.equal(code, 1);
  assert.equal(await readFile(marker, "utf8"), "yes");
});

test("an operator termination stops both children cleanly", async () => {
  const signals = new EventEmitter();
  setTimeout(() => signals.emit("SIGTERM"), 50);

  const cleanChild = ["-e", "process.on('SIGTERM',()=>process.exit(0));setInterval(()=>{},1000)"];
  const code = await supervise([
    { name: "one", command: process.execPath, args: cleanChild },
    { name: "two", command: process.execPath, args: cleanChild },
  ], { graceMs: 500, signalSource: signals, logger: quietLogger });

  assert.equal(code, 0);
});

test("a spawn failure stops children and fails the runtime", async () => {
  const code = await supervise([
    { name: "sleeper", command: process.execPath, args: ["-e", "setInterval(()=>{},1000)"] },
    { name: "missing", command: "/definitely/missing/huddle-command" },
  ], { graceMs: 100, signalSource: new EventEmitter(), logger: quietLogger });

  assert.equal(code, 1);
});
