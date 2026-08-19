import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { delay, stopChild } from './process';

const harnessPort = Number(process.env.IOS_HARNESS_PORT || 3100);
const apiUrl = `http://127.0.0.1:${harnessPort}`;
const useLocalHub = process.env.IOS_USE_LOCAL_HUB === 'true';
const hubPort = Number(process.env.E2E_HUB_PORT || 8788);
const hubUrl =
  process.env.IOS_HUB_BASE_URL ||
  (useLocalHub ? `http://127.0.0.1:${hubPort}` : 'https://rownd-hub.supertokens.com');
const hubHealthUrl = useLocalHub ? `${hubUrl}/health` : hubUrl;
const localHubRepo = path.resolve(process.env.IOS_LOCAL_HUB_REPO || '../supertokens-rownd-hub');
const tunnelHostHeader = 'rownd-e2e-public';
let environment: NodeJS.ProcessEnv = {
  ...process.env,
  IOS_HARNESS_PORT: String(harnessPort),
  IOS_HUB_BASE_URL: hubUrl,
  IOS_HUB_HEALTH_URL: hubHealthUrl,
  TEST_BACKEND_URL: apiUrl,
};

let harnessProcess: ChildProcess | undefined;
let harnessFailure: Error | undefined;
let hubProcess: ChildProcess | undefined;
let hubFailure: Error | undefined;
let activeCommand: ChildProcess | undefined;
let tunnelProcess: ChildProcess | undefined;
let tunnelFailure: Error | undefined;
let shutdownPromise: Promise<void> | undefined;

function startTunnel() {
  const child = spawn(
    'cloudflared',
    [
      'tunnel',
      '--url',
      apiUrl,
      '--protocol',
      'http2',
      '--http-host-header',
      tunnelHostHeader,
      '--no-autoupdate',
    ],
    {
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: false,
      detached: process.platform !== 'win32',
    },
  );
  tunnelProcess = child;

  return new Promise<string>((resolve, reject) => {
    let settled = false;
    let outputBuffer = '';
    const timeout = setTimeout(() => finish(new Error('Timed out waiting for the Cloudflare tunnel URL')), 60_000);

    function finish(result: string | Error) {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      result instanceof Error ? reject(result) : resolve(result);
    }

    function handleOutput(data: Buffer) {
      const output = data.toString();
      process.stderr.write(output);
      outputBuffer = `${outputBuffer}${output}`.slice(-16_384);
      const tunnelUrl = outputBuffer.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/)?.[0];
      if (tunnelUrl) {
        finish(tunnelUrl);
      }
    }

    child.stdout?.on('data', handleOutput);
    child.stderr?.on('data', handleOutput);
    child.once('error', (error) => {
      tunnelFailure = error;
      finish(error);
    });
    child.once('exit', (code, signal) => {
      const error = new Error(`Cloudflare tunnel exited unexpectedly (code ${code}, signal ${signal})`);
      finish(error);
      if (tunnelProcess === child) {
        tunnelFailure = error;
        void stopChild(activeCommand);
      }
    });
  });
}

function start(command: string, args: string[], env = environment, cwd = process.cwd()) {
  return spawn(command, args, {
    cwd,
    stdio: 'inherit',
    shell: false,
    detached: process.platform !== 'win32',
    env,
  });
}

async function run(command: string, args: string[], cwd = process.cwd()) {
  const child = start(command, args, environment, cwd);
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

async function startLocalHub() {
  await run('npm', ['run', 'build'], localHubRepo);

  const hubServerPath = path.join(localHubRepo, 'test/e2e/harness/hub-server.ts');
  hubProcess = start(
    process.execPath,
    ['--import', 'tsx', hubServerPath],
    { ...environment, E2E_HUB_PORT: String(hubPort) },
    localHubRepo,
  );
  const startedHub = hubProcess;
  const handleHubFailure = (error: Error) => {
    if (hubProcess === startedHub) {
      hubFailure = error;
      void stopChild(activeCommand);
    }
  };
  startedHub.once('error', handleHubFailure);
  startedHub.once('exit', (code, signal) => {
    handleHubFailure(new Error(`Local Hub exited unexpectedly (code ${code}, signal ${signal})`));
  });
}

function assertResourcesRunning() {
  if (harnessFailure) {
    throw harnessFailure;
  }
  if (!harnessProcess || harnessProcess.exitCode !== null || harnessProcess.signalCode !== null) {
    throw new Error('The integration harness exited unexpectedly');
  }
  if (tunnelFailure) {
    throw tunnelFailure;
  }
  if (hubFailure) {
    throw hubFailure;
  }
}

async function waitForHealth(url: string, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    assertResourcesRunning();
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
    const hubToStop = hubProcess;
    const tunnelToStop = tunnelProcess;
    activeCommand = undefined;
    harnessProcess = undefined;
    hubProcess = undefined;
    tunnelProcess = undefined;

    await stopResource('active E2E command', errors, () => stopChild(commandToStop));
    await stopResource('integration harness process', errors, () => stopChild(harnessToStop, 30_000));
    await stopResource('local Hub process', errors, () => stopChild(hubToStop));
    await stopResource('Cloudflare tunnel process', errors, () => stopChild(tunnelToStop));

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
  let failure: unknown;
  try {
    let publicApiUrl: string | undefined;
    if (useLocalHub) {
      await startLocalHub();
    } else {
      publicApiUrl = validatePublicApiUrl(await startTunnel());
      environment = {
        ...environment,
        IOS_PUBLIC_API_URL: publicApiUrl,
        IOS_PUBLIC_TUNNEL_HOST_HEADER: tunnelHostHeader,
      };
    }
    harnessProcess = start(process.execPath, ['--import', 'tsx', 'test-server/run-harness.ts']);
    const startedHarness = harnessProcess;
    const handleHarnessFailure = (error: Error) => {
      if (harnessProcess === startedHarness) {
        harnessFailure = error;
        void stopChild(activeCommand);
      }
    };
    startedHarness.once('error', handleHarnessFailure);
    startedHarness.once('exit', (code, signal) => {
      handleHarnessFailure(new Error(`Integration harness exited unexpectedly (code ${code}, signal ${signal})`));
    });

    await Promise.all([
      waitForHealth(`${apiUrl}/health`),
      ...(publicApiUrl ? [waitForHealth(`${publicApiUrl}/health`)] : []),
      waitForHealth(hubHealthUrl),
    ]);
    await run('npm', ['run', 'test:integration']);
    assertResourcesRunning();
    await run('npm', ['run', 'test:e2e:example']);
    assertResourcesRunning();
    await run('npm', ['run', process.env.IOS_E2E_UI_SCRIPT || 'test:e2e:ui']);
    assertResourcesRunning();
  } catch (error) {
    failure = error;
  }

  try {
    await shutdown();
  } catch (cleanupError) {
    if (failure) {
      throw new AggregateError([failure, cleanupError], 'E2E run and cleanup failed');
    }
    throw cleanupError;
  }

  if (failure) {
    throw failure;
  }
}

function validatePublicApiUrl(value: string) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('IOS_PUBLIC_API_URL must be an HTTPS origin without a path, query, or fragment');
  }
  return url.origin;
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
