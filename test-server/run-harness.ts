import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { stopChild } from './process';
import { startIntegrationHarness } from './server';

// The Rownd plugin creates a default Rownd client during init. That client starts
// a background app-config fetch using test credentials before the harness replaces
// it with a mock client. This mirrors the Hub E2E harness behavior.
process.on('unhandledRejection', (reason) => {
  if (reason instanceof Error && reason.message.startsWith('Failed to fetch app config')) {
    return;
  }
  console.error('Unhandled rejection:', reason);
  void shutdown(1);
});

let harness: Awaited<ReturnType<typeof startIntegrationHarness>> | undefined;
let hubProcess: ChildProcess | undefined;
let activeCommandProcess: ChildProcess | undefined;
let isShuttingDown = false;
let shutdownPromise: Promise<void> | undefined;
let shutdownExitCode = 0;

const hubRepoDir = path.resolve(process.cwd(), '../supertokens-rownd-hub');
const hubPort = Number(process.env.E2E_HUB_PORT || 8787);

function run(command: string, args: string[], cwd: string) {
  const child = spawn(command, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
    detached: process.platform !== 'win32',
  });
  activeCommandProcess = child;

  return new Promise<void>((resolve, reject) => {
    child.on('exit', (code) => {
      if (activeCommandProcess === child) {
        activeCommandProcess = undefined;
      }
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(`${command} ${args.join(' ')} exited with ${code}`));
    });
    child.on('error', reject);
  });
}

async function waitForHealth(url: string, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // Keep polling until the server is ready or the timeout is reached.
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  throw new Error(`Timed out waiting for ${url}`);
}

async function startHubServer() {
  await run('npm', ['run', 'build'], hubRepoDir);

  const hubServerPath = path.join(hubRepoDir, 'test/e2e/harness/hub-server.ts');
  hubProcess = spawn(process.execPath, ['--import', 'tsx', hubServerPath], {
    cwd: hubRepoDir,
    stdio: 'inherit',
    shell: false,
    env: {
      ...process.env,
      E2E_HUB_PORT: String(hubPort),
    },
  });

  const startedProcess = hubProcess;
  const exitedBeforeReady = new Promise<never>((_, reject) => {
    startedProcess.once('error', reject);
    startedProcess.once('exit', (code, signal) => {
      reject(new Error(`Hub server exited before becoming ready (code ${code}, signal ${signal})`));
    });
  });

  await Promise.race([waitForHealth(`http://127.0.0.1:${hubPort}/health`), exitedBeforeReady]);

  startedProcess.on('exit', (code, signal) => {
    if (!isShuttingDown) {
      console.error(`Hub server exited unexpectedly (code ${code}, signal ${signal})`);
      void shutdown(1);
    }
  });
}

function shutdown(exitCode = 0) {
  if (exitCode !== 0) {
    shutdownExitCode = exitCode;
  }

  if (shutdownPromise) {
    return shutdownPromise;
  }

  isShuttingDown = true;
  shutdownPromise = (async () => {
    const errors: unknown[] = [];
    const commandToStop = activeCommandProcess;
    const harnessToStop = harness;
    const hubToStop = hubProcess;
    activeCommandProcess = undefined;
    harness = undefined;
    hubProcess = undefined;

    await stopResource('active command', errors, () => stopChild(commandToStop));
    await stopResource('iOS integration harness', errors, () => harnessToStop?.stop());
    await stopResource('Hub server', errors, () => stopChild(hubToStop));

    process.exit(errors.length > 0 ? 1 : shutdownExitCode);
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

void startHubServer()
  .then(() => startIntegrationHarness())
  .then((startedHarness) => {
    harness = startedHarness;
    console.log(`iOS integration harness listening at ${startedHarness.apiUrl}`);
    console.log(`Local Hub SDK server listening at http://127.0.0.1:${hubPort}`);
  })
  .catch((error) => {
    console.error('Failed to start iOS integration harness', error);
    void shutdown(1);
  });

process.on('SIGINT', () => {
  void shutdown();
});

process.on('SIGTERM', () => {
  void shutdown();
});
