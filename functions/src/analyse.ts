import { onRequest } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { getStorage } from 'firebase-admin/storage';
import {
  checkUsageAvailable,
  incrementUsage,
  isLimitExceededError,
  sendDailyQuotaExceededResponse,
} from './usageGuard';
import { callGemini } from './gemini';
import { runWithAppCheck } from './appCheck';

const REGION = 'us-central1';
const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;
const MAX_VERTEX_RESPONSE_ATTEMPTS = 2;

type AnalysisPayload = {
  primary_emotion: string;
  confidence_score: number;
  analysis: string;
  persona_type: string;
  cat_thought: string;
  owner_tip: string;
};

class InvalidVertexResponseError extends Error {
  constructor(
    message: string,
    readonly issues: string[],
    readonly rawResponse: string
  ) {
    super(message);
    this.name = 'InvalidVertexResponseError';
  }
}

export const analyseVideo = onRequest(
  {
    region: REGION,
    // Public at the IAM layer so mobile clients can reach the endpoint.
    // Firebase App Check is enforced before business logic runs.
    invoker: 'public',
    serviceAccount: 'catvox-backend-sa@kathelix-catvox-prod.iam.gserviceaccount.com',
    timeoutSeconds: 120, // Vertex AI multimodal calls can take up to ~30s; headroom for retries.
    memory: '512MiB',
  },
  async (req, res) => {
    await runWithAppCheck(req, res, async () => {
      if (req.method !== 'POST') {
        res.status(405).send('Method Not Allowed');
        return;
      }

      const { gcsUri, userId } = req.body as {
        gcsUri?: string;
        userId?: string;
      };

      if (!gcsUri || !userId) {
        res.status(400).json({ error: 'gcsUri and userId are required' });
        return;
      }

      try {
        await checkUsageAvailable(userId);
      } catch (err: unknown) {
        if (isLimitExceededError(err)) {
          sendDailyQuotaExceededResponse(res, 'analyseVideo');
          return;
        }
        throw err;
      }

      const projectId = process.env.GCLOUD_PROJECT;
      if (!projectId) throw new Error('GCLOUD_PROJECT env var is not set');

      const objectInfo = parseGcsUri(gcsUri);
      if (!objectInfo) {
        res.status(400).json({ error: 'Invalid gcsUri' });
        return;
      }

      const file = getStorage().bucket(objectInfo.bucketName).file(objectInfo.objectName);
      const [metadata] = await file.getMetadata();

      const sizeBytes = Number(metadata.size ?? 0);
      if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) {
        res.status(400).json({ error: 'Uploaded video metadata is missing a valid size.' });
        return;
      }

      if (sizeBytes > MAX_UPLOAD_BYTES) {
        res.status(413).json({
          error: 'Uploaded video exceeds the 100 MB limit.',
        });
        return;
      }

      const mimeType = normalizedVertexVideoMimeType(metadata.contentType);
      if (!mimeType) {
        res.status(400).json({ error: 'Uploaded object is not a supported video.' });
        return;
      }

      try {
        const parsed = await getAnalysisPayload(() =>
          callGemini(projectId, gcsUri, mimeType)
        );

        await incrementUsage(userId);
        res.status(200).json(parsed);
      } catch (err: unknown) {
        if (err instanceof InvalidVertexResponseError) {
          logger.error('Vertex AI returned malformed analysis payload', {
            issues: err.issues,
            rawResponsePreview: previewRawResponse(err.rawResponse),
            gcsUri,
          });
          res.status(502).json({
            error: 'Analysis service returned an invalid response. Please try again.',
          });
          return;
        }

        throw err;
      }
    });
  }
);

export async function getAnalysisPayload(
  getRawResponse: () => Promise<string>
): Promise<AnalysisPayload> {
  let lastError: InvalidVertexResponseError | null = null;

  for (let attempt = 1; attempt <= MAX_VERTEX_RESPONSE_ATTEMPTS; attempt += 1) {
    const rawResponse = await getRawResponse();

    try {
      return parseAnalysisPayload(rawResponse);
    } catch (err: unknown) {
      if (!(err instanceof InvalidVertexResponseError)) {
        throw err;
      }

      lastError = err;

      if (attempt < MAX_VERTEX_RESPONSE_ATTEMPTS) {
        logger.warn('Retrying malformed Vertex AI analysis payload', {
          attempt,
          issues: err.issues,
          rawResponsePreview: previewRawResponse(err.rawResponse),
        });
      }
    }
  }

  throw lastError ?? new Error('Vertex AI response validation failed');
}

export function parseAnalysisPayload(rawResponse: string): AnalysisPayload {
  let parsed: unknown;

  try {
    parsed = JSON.parse(rawResponse);
  } catch {
    throw new InvalidVertexResponseError(
      'Vertex AI returned invalid JSON.',
      ['invalid_json'],
      rawResponse
    );
  }

  const issues = validateAnalysisPayload(parsed);
  if (issues.length > 0) {
    throw new InvalidVertexResponseError(
      'Vertex AI returned an invalid analysis payload.',
      issues,
      rawResponse
    );
  }

  return parsed as AnalysisPayload;
}

function parseGcsUri(gcsUri: string): { bucketName: string; objectName: string } | null {
  const match = /^gs:\/\/([^/]+)\/(.+)$/.exec(gcsUri);
  if (!match) {
    return null;
  }

  return {
    bucketName: match[1],
    objectName: match[2],
  };
}

function normalizedVertexVideoMimeType(contentType?: string): string | null {
  switch (contentType) {
    case 'video/mp4':
    case 'video/mov':
    case 'video/quicktime':
    case 'video/mpeg':
    case 'video/mpg':
    case 'video/avi':
    case 'video/wmv':
    case 'video/mpegps':
    case 'video/flv':
    case 'video/x-flv':
      return contentType;
    case 'video/x-m4v':
      return 'video/mp4';
    default:
      return null;
  }
}

function validateAnalysisPayload(value: unknown): string[] {
  if (!isRecord(value)) {
    return ['payload_not_object'];
  }

  const issues: string[] = [];

  for (const key of [
    'primary_emotion',
    'analysis',
    'persona_type',
    'cat_thought',
    'owner_tip',
  ] as const) {
    if (typeof value[key] !== 'string' || value[key].trim().length === 0) {
      issues.push(`invalid_${key}`);
    }
  }

  if (
    typeof value.confidence_score !== 'number' ||
    !Number.isFinite(value.confidence_score) ||
    value.confidence_score < 0 ||
    value.confidence_score > 1
  ) {
    issues.push('invalid_confidence_score');
  }

  return issues;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function previewRawResponse(rawResponse: string): string {
  return rawResponse.length > 500 ? `${rawResponse.slice(0, 500)}...` : rawResponse;
}
