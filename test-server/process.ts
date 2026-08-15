import type { ChildProcess } from 'node:child_process';

export function delay(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function signalProcessGroup(child: ChildProcess, signal: NodeJS.Signals) {
  if (child.pid && process.platform !== 'win32') {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch {
      // The process may have exited between the liveness check and the signal.
    }
  }
  child.kill(signal);
}

function waitForExit(child: ChildProcess, timeoutMs: number) {
  return new Promise<boolean>((resolve) => {
    const onExit = () => {
      clearTimeout(timeout);
      resolve(true);
    };
    const timeout = setTimeout(() => {
      child.removeListener('exit', onExit);
      resolve(false);
    }, timeoutMs);
    child.once('exit', onExit);
    if (child.exitCode !== null || child.signalCode !== null) {
      child.removeListener('exit', onExit);
      clearTimeout(timeout);
      resolve(true);
    }
  });
}

export async function stopChild(child: ChildProcess | undefined, gracePeriodMs = 5_000) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return;
  }

  signalProcessGroup(child, 'SIGTERM');
  if (!(await waitForExit(child, gracePeriodMs))) {
    signalProcessGroup(child, 'SIGKILL');
    await waitForExit(child, 5_000);
  }
}
