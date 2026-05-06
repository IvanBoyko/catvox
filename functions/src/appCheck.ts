import * as logger from 'firebase-functions/logger';
import { getAppCheck } from 'firebase-admin/app-check';

export const APP_CHECK_UNAUTHORIZED_CODE = 'app_check_unauthorized';
const APP_CHECK_UNAUTHORIZED_MESSAGE = 'App Check token is missing or invalid.';
const APP_CHECK_HEADER = 'X-Firebase-AppCheck';

export type AppCheckUnauthorizedBody = {
  code: typeof APP_CHECK_UNAUTHORIZED_CODE;
  message: string;
};

type AppCheckRequestLike = {
  header(name: string): string | undefined;
};

type AppCheckResponseLike = {
  status(code: number): {
    json(body: AppCheckUnauthorizedBody): unknown;
  };
};

export type VerifyAppCheckToken = (token: string) => Promise<unknown>;

export async function runWithAppCheck(
  req: AppCheckRequestLike,
  res: AppCheckResponseLike,
  handler: () => void | Promise<void>,
  verifyToken: VerifyAppCheckToken = verifyFirebaseAppCheckToken
): Promise<void> {
  if (!(await verifyAppCheckRequest(req, res, verifyToken))) {
    return;
  }

  await handler();
}

export async function verifyAppCheckRequest(
  req: AppCheckRequestLike,
  res: AppCheckResponseLike,
  verifyToken: VerifyAppCheckToken = verifyFirebaseAppCheckToken
): Promise<boolean> {
  const token = req.header(APP_CHECK_HEADER);

  if (!token) {
    sendAppCheckUnauthorizedResponse(res, 'missing_token');
    return false;
  }

  try {
    await verifyToken(token);
    return true;
  } catch (err: unknown) {
    logger.warn('app_check_unauthorized', {
      event: 'app_check_unauthorized',
      reason: 'invalid_token',
      error: err instanceof Error ? err.message : String(err),
    });
    sendAppCheckUnauthorizedResponse(res, 'invalid_token');
    return false;
  }
}

function verifyFirebaseAppCheckToken(token: string): Promise<unknown> {
  return getAppCheck().verifyToken(token);
}

function sendAppCheckUnauthorizedResponse(
  res: AppCheckResponseLike,
  reason: 'missing_token' | 'invalid_token'
): void {
  if (reason === 'missing_token') {
    logger.warn('app_check_unauthorized', {
      event: 'app_check_unauthorized',
      reason,
    });
  }

  res.status(401).json({
    code: APP_CHECK_UNAUTHORIZED_CODE,
    message: APP_CHECK_UNAUTHORIZED_MESSAGE,
  });
}
