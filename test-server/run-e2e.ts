import { spawn, type ChildProcess } from 'node:child_process';
import { delay, stopChild } from './process';

const harnessPort = Number(process.env.IOS_HARNESS_PORT || 3100);
const hubPort = Number(process.env.E2E_HUB_PORT || 8788);
const apiUrl = `http://127.0.0.1:${harnessPort}`;
const hubUrl = `http://127.0.0.1:${hubPort}`;
const environment = {
  ...process.env,
  E2E_HUB_PORT: String(hubPort),
  IOS_HARNESS_PORT: String(harnessPort),
  IOS_HUB_BASE_URL: process.env.IOS_HUB_BASE_URL || hubUrl,
  TEST_BACKEND_URL: apiUrl,
  TEST_HUB_URL: hubUrl,
};

let harnessProcess: ChildProcess | undefined;
let activeCommand: ChildProcess | undefined;
let shutdownPromise: Promise<void> | undefined;

function start(command: string, args: string[], env = environment) {
  return spawn(command, args, {
    cwd: process.cwd(),
    stdio: 'inherit',
    shell: false,
    detached: process.platform !== 'win32',
    env,
  });
}

async function run(command: string, args: string[]) {
  const child = start(command, args);
  activeCommand = child;

  try {
    await new Promise<void>((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => {
        if (code === 0) {
          resolve();
          return;
        }
        reject(new Error(`${command} ${args.join(' ')} exited with code ${code}, signal ${signal}`));
      });
    });
  } finally {
    if (activeCommand === child) {
      activeCommand = undefined;
    }
  }
}

function assertHarnessRunning() {
  if (!harnessProcess || harnessProcess.exitCode !== null || harnessProcess.signalCode !== null) {
    throw new Error('The integration harness exited unexpectedly');
  }
}

async function waitForHealth(url: string, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    assertHarnessRunning();
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(2_000) });
      if (response.ok) {
        return;
      }
    } catch {
      // Keep polling while the harness process is alive.
    }
    await delay(500);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function shutdown() {
  if (shutdownPromise) {
    return shutdownPromise;
  }

  shutdownPromise = (async () => {
    const errors: unknown[] = [];
    const commandToStop = activeCommand;
    const harnessToStop = harnessProcess;
    activeCommand = undefined;
    harnessProcess = undefined;

    await stopResource('active E2E command', errors, () => stopChild(commandToStop));
    await stopResource('integration harness process', errors, () => stopChild(harnessToStop, 30_000));

    if (errors.length > 0) {
      throw new AggregateError(errors, 'Failed to stop one or more iOS E2E resources');
    }
  })();

  return shutdownPromise;
}

async function stopResource(
  name: string,
  errors: unknown[],
  stop: () => Promise<unknown> | undefined,
) {
  try {
    await stop();
  } catch (error) {
    console.error(`Failed to stop ${name}`, error);
    errors.push(error);
  }
}

async function main() {
  harnessProcess = start(process.execPath, ['--import', 'tsx', 'test-server/run-harness.ts']);

  try {
    await Promise.all([waitForHealth(`${apiUrl}/health`), waitForHealth(`${hubUrl}/health`)]);
    await run('npm', ['run', 'test:integration']);
    assertHarnessRunning();
    await run('npm', ['run', 'test:e2e:example']);
    assertHarnessRunning();
    await run('npm', ['run', 'test:e2e:ui']);
    assertHarnessRunning();
  } finally {
    await shutdown();
  }
}

process.once('SIGINT', () => {
  void shutdown().then(
    () => process.exit(130),
    () => process.exit(1),
  );
});
process.once('SIGTERM', () => {
  void shutdown().then(
    () => process.exit(143),
    () => process.exit(1),
  );
});

void main().catch((error) => {
  console.error('iOS E2E run failed', error);
  process.exitCode = 1;
});
