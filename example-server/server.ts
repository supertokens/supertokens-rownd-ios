import cors from "cors";
import express from "express";
import { existsSync, readFileSync } from "fs";
import SuperTokens from "supertokens-node";
import AccountLinking from "supertokens-node/recipe/accountlinking";
import EmailVerification from "supertokens-node/recipe/emailverification";
import Passwordless from "supertokens-node/recipe/passwordless";
import Session from "supertokens-node/recipe/session";
import { verifySession } from "supertokens-node/recipe/session/framework/express";
import ThirdParty from "supertokens-node/recipe/thirdparty";
import UserMetadata from "supertokens-node/recipe/usermetadata";
import {
  errorHandler,
  middleware,
  type SessionRequest,
} from "supertokens-node/framework/express";
import RowndMigrationPlugin from "@supertokens-plugins/rownd-nodejs";

loadEnvFile("example-server/.env");

function loadEnvFile(path: string) {
  if (!existsSync(path)) {
    return;
  }

  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    const separator = trimmed.indexOf("=");
    if (separator === -1) {
      continue;
    }

    const key = trimmed.slice(0, separator).trim();
    const value = trimmed
      .slice(separator + 1)
      .trim()
      .replace(/^[\'"]|[\'"]$/g, "");
    process.env[key] ??= value;
  }
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

function optionalEnv(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

const port = Number(process.env.PORT ?? 3137);
const apiBasePath = process.env.API_BASE_PATH ?? "/auth";
const apiDomain = process.env.API_DOMAIN ?? `http://localhost:${port}`;
const allowedOrigins = (
  process.env.ALLOWED_ORIGINS ??
  "https://staging.supertokens-rownd-hub.pages.dev"
)
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);
const googleClientId = requireEnv("GOOGLE_CLIENT_ID");
const googleClientSecret = requireEnv("GOOGLE_CLIENT_SECRET");
const googleIosClientId = optionalEnv("GOOGLE_IOS_CLIENT_ID");
const appleClientId = optionalEnv("APPLE_CLIENT_ID");
const appleClientSecret = optionalEnv("APPLE_CLIENT_SECRET");

const thirdPartyProviders = [
  {
    config: {
      thirdPartyId: "google",
      clients: [
        {
          clientId: googleClientId,
          clientSecret: googleClientSecret,
        },
      ],
    },
  },
];

if (appleClientId && appleClientSecret) {
  thirdPartyProviders.push({
    config: {
      thirdPartyId: "apple",
      clients: [
        {
          clientId: appleClientId,
          clientSecret: appleClientSecret,
        },
      ],
    },
  });
}

SuperTokens.init({
  supertokens: {
    connectionURI: requireEnv("SUPERTOKENS_CONNECTION_URI"),
    ...(process.env.SUPERTOKENS_API_KEY
      ? { apiKey: process.env.SUPERTOKENS_API_KEY }
      : {}),
  },
  appInfo: {
    appName: process.env.APP_NAME ?? "Rownd iOS Example",
    apiDomain,
    websiteDomain:
      allowedOrigins[0] ?? "https://staging.supertokens-rownd-hub.pages.dev",
    apiBasePath,
  },
  recipeList: [
    AccountLinking.init({}),
    Session.init(),
    UserMetadata.init(),
    Passwordless.init({
      contactMethod: "EMAIL_OR_PHONE",
      flowType: "MAGIC_LINK",
    }),
    EmailVerification.init({
      mode:
        process.env.EMAIL_VERIFICATION_MODE === "REQUIRED"
          ? "REQUIRED"
          : "OPTIONAL",
    }),
    ThirdParty.init({
      signInAndUpFeature: {
        providers: thirdPartyProviders,
      },
    }),
  ],
  experimental: {
    plugins: [
      RowndMigrationPlugin.init({
        rowndAppKey: requireEnv("ROWND_APP_KEY"),
        rowndAppSecret: requireEnv("ROWND_APP_SECRET"),
        enableDebugLogs: process.env.ROWND_ENABLE_DEBUG_LOGS === "true",
        ...(process.env.ROWND_MOBILE_CLIENT_DOMAIN
          ? {
              clientDomains: {
                mobile: process.env.ROWND_MOBILE_CLIENT_DOMAIN,
              },
            }
          : {}),
        schema: {
          zip_code: {
            display_name: "Zip code",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: true,
          },
          last_name: {
            display_name: "Last name",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: true,
          },
          nick_name: {
            display_name: "Nick name",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: true,
          },
          first_name: {
            display_name: "First name",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: true,
          },
          email: {
            display_name: "Email",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: false,
          },
          phone_number: {
            display_name: "Phone number",
            type: "string",
            owned_by: "user",
            user_visible: true,
            show_empty: false,
          },
          google_id: {
            display_name: "Google ID",
            type: "string",
            owned_by: "app",
            user_visible: false,
            read_only: true,
            show_empty: false,
          },
        },
        appConfig: {
          id: process.env.ROWND_APP_KEY,
          name: process.env.APP_NAME ?? "Rownd iOS Example",
          signInMethods: [
            { method: "email" },
            { method: "phone" },
            {
              method: "google",
              clientId: googleClientId,
              ...(googleIosClientId ? { iosClientId: googleIosClientId } : {}),
            },
            ...(appleClientId
              ? [{ method: "apple" as const, clientId: appleClientId }]
              : []),
            {
              method: "anonymous",
              type: "guest",
              displayName: "Continue as guest",
            },
          ],
          profile: {
            accountInformation: {
              methods: {
                email: { enabled: true },
                phone: { enabled: true },
                google: { enabled: true },
                ...(appleClientId ? { apple: { enabled: true } } : {}),
              },
            },
            personalInformation: { enabled: true },
            preferences: { enabled: true },
            signOutButton: { enabled: true },
            deleteAccountButton: { enabled: true },
          },
        },
      }),
    ],
  },
});

const app = express();
let refreshSimulationCompleted = false;

app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.includes(origin)) {
        callback(null, origin || allowedOrigins[0]);
        return;
      }

      callback(new Error(`Origin not allowed by CORS: ${origin}`));
    },
    credentials: true,
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allowedHeaders: [
      "content-type",
      "authorization",
      "ngrok-skip-browser-warning",
      ...SuperTokens.getAllCORSHeaders(),
    ],
    exposedHeaders: [
      "front-token",
      "st-access-token",
      "st-refresh-token",
      "anti-csrf",
    ],
  }),
);

app.use((req, res, next) => {
  res.on("finish", () => {
    console.log(req.headers);
    console.log("Rownd user request", {
      method: req.method,
      path: req.path,
      body: req.body,
      status: res.statusCode,
      hasAuthorization: typeof req.headers.authorization === "string",
      hasStAccessToken: typeof req.headers["st-access-token"] === "string",
      hasStRefreshToken: typeof req.headers["st-refresh-token"] === "string",
      hasRid: typeof req.headers.rid === "string",
      hasFdiVersion: typeof req.headers["fdi-version"] === "string",
      hasAntiCsrf: typeof req.headers["anti-csrf"] === "string",
    });
  });

  next();
});

app.use(middleware());

app.get("/health", (_req, res) => {
  res.json({ status: "OK" });
});

app.get("/sessioninfo", verifySession(), (req: SessionRequest, res) => {
  res.json({
    status: "OK",
    userId: req.session!.getUserId(),
  });
});

app.get("/test/protected", verifySession(), (req: SessionRequest, res) => {
  res.json({
    status: "OK",
    userId: req.session!.getUserId(),
    accessTokenPayload: req.session!.getAccessTokenPayload(),
  });
});

app.post("/test/refresh/reset", (_req, res) => {
  refreshSimulationCompleted = false;
  res.json({ status: "OK", refreshSimulationCompleted });
});

app.get(
  "/test/refresh",
  (_req, res, next) => {
    if (!refreshSimulationCompleted) {
      refreshSimulationCompleted = true;
      res.status(401).json({
        status: "REFRESH_REQUIRED",
        message: "Forced 401 to test SuperTokens session refresh",
      });
      return;
    }

    next();
  },
  verifySession(),
  (req: SessionRequest, res) => {
    res.json({
      status: "OK",
      userId: req.session!.getUserId(),
      accessTokenPayload: req.session!.getAccessTokenPayload(),
      refreshSimulationCompleted,
    });
  },
);

app.use(errorHandler());

app.listen(port, () => {
  console.log(`iOS example backend listening on ${apiDomain}`);
  console.log(`SuperTokens APIs mounted at ${apiDomain}${apiBasePath}`);
  console.log(`Allowed origins: ${allowedOrigins.join(", ")}`);
});
