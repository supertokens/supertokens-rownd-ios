import { spawn } from 'node:child_process';
import type { Server } from 'node:http';
import path from 'node:path';
import express from 'express';
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
let hubServer: Server | undefined;
let isShuttingDown = false;

const hubRepoDir = path.resolve(process.cwd(), '../supertokens-rownd-hub');
const hubPort = Number(process.env.E2E_HUB_PORT || 8787);

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

  const app = express();
  const distDir = path.join(hubRepoDir, 'dist');

  app.use((_, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', 'http://127.0.0.1:3100');
    next();
  });

  app.get('/health', (_req, res) => {
    res.json({ status: 'OK' });
  });

  app.use(express.static(distDir));

  hubServer = await new Promise<Server>((resolve) => {
    const listeningServer = app.listen(hubPort, '127.0.0.1', () => resolve(listeningServer));
  });

  await waitForHealth(`http://127.0.0.1:${hubPort}/health`);
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
      await new Promise<void>((resolve, reject) => {
        hubServer?.close((error) => {
          if (error) {
            reject(error);
            return;
          }

          resolve();
        });
      });
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
    console.log(`Local Hub SDK server listening at http://127.0.0.1:${hubPort}`);
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
