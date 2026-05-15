import { onRequest } from 'firebase-functions/v2/https';
import { getStorage } from 'firebase-admin/storage';
import { randomUUID } from 'crypto';
import {
  checkUsageAvailable,
  isLimitExceededError,
  sendDailyQuotaExceededResponse,
} from './usageGuard';
import { runWithAppCheck } from './appCheck';
import {
  backendServiceAccountOption,
  functionRegion,
  requiredProjectId,
} from './config';

const URL_TTL_MS = 15 * 60 * 1000; // 15 minutes — enough for any upload

export const getSignedUploadURL = onRequest(
  {
    region: functionRegion(),
    // Public at the IAM layer so mobile clients can reach the endpoint.
    // Firebase App Check is enforced before business logic runs.
    invoker: 'public',
    ...backendServiceAccountOption(),
  },
  async (req, res) => {
    await runWithAppCheck(req, res, async () => {
      if (req.method !== 'POST') {
        res.status(405).send('Method Not Allowed');
        return;
      }

      const { filename, contentType, userId } = req.body as {
        filename?: string;
        contentType?: string;
        userId?: string;
      };

      if (!filename || !contentType || !userId) {
        res.status(400).json({ error: 'filename, contentType, and userId are required' });
        return;
      }

      try {
        await checkUsageAvailable(userId);
      } catch (err: unknown) {
        if (isLimitExceededError(err)) {
          sendDailyQuotaExceededResponse(res, 'getSignedUploadURL');
          return;
        }
        throw err;
      }

      const projectId = requiredProjectId();

      const bucketName = `catvox-raw-videos-${projectId}`;
      const objectName = `${randomUUID()}-${filename}`;

      const bucket = getStorage().bucket(bucketName);
      const file = bucket.file(objectName);

      const [signedUrl] = await file.getSignedUrl({
        version: 'v4',
        action: 'write',
        expires: Date.now() + URL_TTL_MS,
        contentType,
      });

      const gcsUri = `gs://${bucketName}/${objectName}`;

      res.status(200).json({ signedUrl, gcsUri });
    });
  }
);
