import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { startIntegrationHarness } from './server';

// The Rownd plugin creates a default Rownd client during init. That client starts
// a background app-config fetch using test credentials before the harness replaces
// it with a mock client. This mirrors the Hub E2E harness behavior.
process.on('unhandledRejection', (reason) => {
  if (reason instanceof Error && reason.message.startsWith('Failed to fetch app config')) {
    return;
  }
  console.error('Unhandled rejection:', reason);
  process.exit(1);
});

let harness: Awaited<ReturnType<typeof startIntegrationHarness>> | undefined;
let hubServer: ChildProcess | undefined;
let isShuttingDown = false;

const hubRepoDir = path.resolve(process.cwd(), '../supertokens-rownd-hub');
const hubTsxBin = path.join(hubRepoDir, 'node_modules/.bin/tsx');

function run(command: string, args: string[], cwd: string) {
  const child = spawn(command, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
  });

  return new Promise<void>((resolve, reject) => {
    child.on('exit', (code) => {
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

  hubServer = spawn(hubTsxBin, ['./test/e2e/harness/hub-server.ts'], {
    cwd: hubRepoDir,
    stdio: 'inherit',
    shell: false,
  });

  hubServer.on('exit', (code) => {
    if (!isShuttingDown) {
      console.error(`Hub SDK server exited unexpectedly with ${code}`);
      process.exit(1);
    }
  });

  await waitForHealth('http://127.0.0.1:8787/health');
}

async function shutdown(exitCode = 0) {
  if (isShuttingDown) {
    return;
  }

  isShuttingDown = true;

  try {
    if (harness) {
      await harness.stop();
    }
    if (hubServer) {
      hubServer.kill('SIGTERM');
      hubServer = undefined;
    }
  } catch (error) {
    console.error('Failed to stop iOS integration harness', error);
    process.exit(1);
  }

  process.exit(exitCode);
}

void startHubServer()
  .then(() => startIntegrationHarness())
  .then((startedHarness) => {
    harness = startedHarness;
    console.log(`iOS integration harness listening at ${startedHarness.apiUrl}`);
    console.log('Local Hub SDK server listening at http://127.0.0.1:8787');
  })
  .catch((error) => {
    console.error('Failed to start iOS integration harness', error);
    process.exit(1);
  });

process.on('SIGINT', () => {
  void shutdown();
});

process.on('SIGTERM', () => {
  void shutdown();
});
