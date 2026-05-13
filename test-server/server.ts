import RowndMigrationPlugin, { setRowndClient } from '@supertokens-plugins/rownd-nodejs';
import cors from 'cors';
import express from 'express';
import type { Server } from 'http';
import { generateKeyPairSync } from 'node:crypto';
import SuperTokens, { RecipeUserId } from 'supertokens-node';
import { errorHandler, middleware } from 'supertokens-node/framework/express';
import Passwordless from 'supertokens-node/recipe/passwordless';
import Session from 'supertokens-node/recipe/session';
import { verifySession } from 'supertokens-node/recipe/session/framework/express';
import ThirdParty from 'supertokens-node/recipe/thirdparty';
import UserMetadata from 'supertokens-node/recipe/usermetadata';
import { GenericContainer, Network, type StartedNetwork, type StartedTestContainer, Wait } from 'testcontainers';

type HarnessCounters = {
  createSession: number;
  signOut: number;
  stRefresh: number;
  legacyRefresh: number;
  migrate: number;
  protected: number;
};

type IntegrationHarness = {
  apiUrl: string;
  stop: () => Promise<void>;
};

const port = Number(process.env.IOS_HARNESS_PORT || 3100);
const appName = 'Rownd iOS Integration Tests';
const websiteDomain = 'http://127.0.0.1:5173';
const hubBaseUrl = process.env.IOS_HUB_BASE_URL || 'http://127.0.0.1:8787';
const appId = 'app_test_rownd_ios';
const appKey = 'test_app_key';

let network: StartedNetwork | undefined;
let postgresContainer: StartedTestContainer | undefined;
let coreContainer: StartedTestContainer | undefined;
let server: Server | undefined;

const counters: HarnessCounters = {
  createSession: 0,
  signOut: 0,
  stRefresh: 0,
  legacyRefresh: 0,
  migrate: 0,
  protected: 0,
};

function resetCounters() {
  counters.createSession = 0;
  counters.signOut = 0;
  counters.stRefresh = 0;
  counters.legacyRefresh = 0;
  counters.migrate = 0;
  counters.protected = 0;
}

export async function startIntegrationHarness(): Promise<IntegrationHarness> {
  resetCounters();
  const { privateKey: applePrivateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const testApplePrivateKey = applePrivateKey.export({ type: 'sec1', format: 'pem' }).toString();

  network = await new Network().start();
  postgresContainer = await new GenericContainer('postgres:14')
    .withNetwork(network)
    .withNetworkAliases('postgres')
    .withEnvironment({
      POSTGRES_USER: 'supertokens',
      POSTGRES_PASSWORD: 'somepassword',
      POSTGRES_DB: 'supertokens',
    })
    .withExposedPorts(5432)
    .withWaitStrategy(Wait.forLogMessage('database system is ready to accept connections'))
    .start();

  coreContainer = await new GenericContainer('supertokens/supertokens-postgresql')
    .withNetwork(network)
    .withEnvironment({
      POSTGRESQL_CONNECTION_URI: 'postgresql://supertokens:somepassword@postgres:5432/supertokens',
    })
    .withExposedPorts(3567)
    .withWaitStrategy(Wait.forHttp('/hello', 3567))
    .start();

  const coreConnectionURI = `http://${coreContainer.getHost()}:${coreContainer.getMappedPort(3567)}`;
  const app = express();

  const started = await new Promise<{ server: Server; port: number }>((resolve) => {
    const listeningServer = app.listen(port, () => {
      const address = listeningServer.address();

      if (!address || typeof address === 'string') {
        throw new Error('Could not determine iOS integration harness port');
      }

      resolve({ server: listeningServer, port: address.port });
    });
  });

  server = started.server;
  const apiUrl = `http://127.0.0.1:${started.port}`;

  SuperTokens.init({
    supertokens: {
      connectionURI: coreConnectionURI,
    },
    appInfo: {
      appName,
      apiDomain: apiUrl,
      websiteDomain,
    },
    recipeList: [
      Session.init(),
      UserMetadata.init(),
      ThirdParty.init({
        signInAndUpFeature: {
          providers: [
            {
              config: {
                thirdPartyId: 'google',
                clients: [{ clientId: 'test-google-client-id', clientSecret: 'test-google-client-secret' }],
              },
            },
            {
              config: {
                thirdPartyId: 'apple',
                clients: [
                  {
                    clientId: 'test-apple-client-id',
                    additionalConfig: {
                      teamId: 'TESTTEAM01',
                      keyId: 'TESTKEY0001',
                      privateKey: testApplePrivateKey,
                    },
                  },
                ],
              },
            },
          ],
        },
      }),
      Passwordless.init({
        contactMethod: 'EMAIL_OR_PHONE',
        flowType: 'MAGIC_LINK',
        emailDelivery: { service: { sendEmail: async () => {} } },
        smsDelivery: { service: { sendSms: async () => {} } },
      }),
    ],
    experimental: {
      plugins: [
        RowndMigrationPlugin.init({
          rowndAppKey: appKey,
          rowndAppSecret: 'rownd-e2e-secret-rownd-e2e-secret',
          appConfig: {
            id: appId,
            name: appName,
            signInMethods: [
              { method: 'google', iosClientId: 'test-google-ios-client-id' },
              { method: 'phone' },
              { method: 'email' },
              { method: 'anonymous' },
            ],
          },
        }),
      ],
    },
  });

  setRowndClient({
    validateToken: async () => ({ user_id: 'ios-test-user' }),
    fetchUserInfo: async ({ user_id }: { user_id: string }) => ({
      state: 'enabled',
      auth_level: 'verified',
      data: { user_id, email: `${user_id}@example.com` },
      verified_data: { email: `${user_id}@example.com` },
      groups: [],
      meta: {},
    }) as any,
  });

  app.use(
    cors({
      origin: websiteDomain,
      allowedHeaders: ['content-type', 'x-rownd-app-key', ...SuperTokens.getAllCORSHeaders()],
      exposedHeaders: ['front-token', 'st-access-token', 'st-refresh-token', 'anti-csrf'],
      credentials: true,
    }),
  );
  app.use(express.json());
  app.use((req, _res, next) => {
    if (req.method === 'POST' && req.path === '/auth/session/refresh') {
      counters.stRefresh += 1;
    }
    if (req.method === 'POST' && req.path === '/auth/plugin/rownd/migrate') {
      counters.migrate += 1;
    }
    if (req.method === 'POST' && req.path === '/auth/signout') {
      counters.signOut += 1;
    }

    next();
  });

  app.use(middleware());

  app.post('/hub/auth/token', (_req, res) => {
    counters.legacyRefresh += 1;
    res.json({
      access_token: 'legacy-refreshed-access-token',
      refresh_token: 'legacy-refreshed-refresh-token',
      is_verified_user: true,
    });
  });

  app.get('/health', (_req, res) => {
    res.json({ status: 'OK' });
  });

  app.get('/config', (_req, res) => {
    res.json({
      apiUrl,
      appId,
      appKey,
      hubBaseUrl,
      supertokens: {
        appInfo: {
          apiDomain: apiUrl,
          apiBasePath: '/auth',
        },
      },
    });
  });

  app.post('/reset', (_req, res) => {
    resetCounters();
    res.json({ status: 'OK' });
  });

  app.get('/counters', (_req, res) => {
    res.json(counters);
  });

  app.post('/test/session', async (req: any, res: any) => {
    counters.createSession += 1;
    const userId = typeof req.body?.userId === 'string' ? req.body.userId : 'ios-test-user';

    await Session.createNewSession(req, res, 'public', new RecipeUserId(userId), {}, {}, {});
    res.json({ status: 'OK', userId });
  });

  app.get('/test/protected', verifySession(), async (req: any, res) => {
    counters.protected += 1;
    res.json({
      status: 'OK',
      userId: req.session.getUserId(),
      accessTokenPayload: req.session.getAccessTokenPayload(),
    });
  });

  app.use(errorHandler());

  return {
    apiUrl,
    stop: async () => {
      if (server) {
        await new Promise<void>((resolve, reject) => {
          server?.close((error) => {
            if (error) {
              reject(error);
              return;
            }

            resolve();
          });
        });
        server = undefined;
      }
      if (coreContainer) {
        await coreContainer.stop();
        coreContainer = undefined;
      }
      if (postgresContainer) {
        await postgresContainer.stop();
        postgresContainer = undefined;
      }
      if (network) {
        await network.stop();
        network = undefined;
      }
    },
  };
}
