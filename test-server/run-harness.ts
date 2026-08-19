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
let shutdownPromise: Promise<void> | undefined;
let shutdownExitCode = 0;
let startupPromise: Promise<void>;

function shutdown(exitCode = 0) {
  if (exitCode !== 0) {
    shutdownExitCode = exitCode;
  }

  if (shutdownPromise) {
    return shutdownPromise;
  }

  shutdownPromise = (async () => {
    try {
      await startupPromise;
    } catch {
      // Startup errors are reported by the startup handler below.
    }
    const harnessToStop = harness;
    harness = undefined;

    try {
      await harnessToStop?.stop();
      process.exit(shutdownExitCode);
    } catch (error) {
      console.error('Failed to stop iOS integration harness', error);
      process.exit(1);
    }
  })();

  return shutdownPromise;
}

startupPromise = startIntegrationHarness()
  .then((startedHarness) => {
    harness = startedHarness;
    console.log(`iOS integration harness listening at ${startedHarness.apiUrl}`);
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
