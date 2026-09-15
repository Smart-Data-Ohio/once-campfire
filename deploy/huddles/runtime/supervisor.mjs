import { spawn } from "node:child_process";

export async function supervise(specifications, options = {}) {
  const graceMs = options.graceMs ?? 5_000;
  const signalSource = options.signalSource ?? process;
  const logger = options.logger ?? console;
  const spawnChild = options.spawnChild ?? spawn;
  const children = new Map();
  const signalHandlers = new Map();
  let shutdownCode = null;
  let forceTimer = null;

  return await new Promise((resolve) => {
    const finishIfStopped = () => {
      if (shutdownCode === null || [...children.values()].some(({ exited }) => !exited)) return;
      if (forceTimer) clearTimeout(forceTimer);
      for (const [signal, handler] of signalHandlers) signalSource.off(signal, handler);
      resolve(shutdownCode);
    };

    const stop = (code, reason) => {
      if (shutdownCode !== null) {
        for (const state of children.values()) {
          if (!state.exited) state.child.kill("SIGKILL");
        }
        return;
      }

      shutdownCode = code;
      logger.error(reason);
      for (const state of children.values()) {
        if (!state.exited) state.child.kill("SIGTERM");
      }
      forceTimer = setTimeout(() => {
        for (const [name, state] of children) {
          if (!state.exited) {
            logger.error(`${name} did not stop within ${graceMs}ms; sending SIGKILL`);
            state.child.kill("SIGKILL");
          }
        }
      }, graceMs);
      finishIfStopped();
    };

    for (const specification of specifications) {
      const child = spawnChild(specification.command, specification.args ?? [], {
        cwd: specification.cwd,
        env: specification.env,
        stdio: "inherit",
      });
      const state = { child, exited: false };
      children.set(specification.name, state);

      child.once("error", () => stop(1, `${specification.name} failed to start; stopping supervised runtime`));
      child.once("close", (code, signal) => {
        state.exited = true;
        if (shutdownCode === null) {
          const result = signal ? `signal ${signal}` : `status ${code}`;
          stop(1, `${specification.name} exited with ${result}; stopping supervised runtime`);
        }
        finishIfStopped();
      });
    }

    for (const signal of ["SIGINT", "SIGTERM"]) {
      const handler = () => stop(0, `Supervisor received ${signal}; stopping media services`);
      signalHandlers.set(signal, handler);
      signalSource.once(signal, handler);
    }
  });
}
