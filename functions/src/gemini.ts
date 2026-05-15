import {
  GoogleGenAI,
  HarmCategory,
  HarmBlockThreshold,
  Type,
  type GenerateContentConfig,
  type Part,
  type Schema,
} from '@google/genai';
import { readFileSync } from 'fs';
import { join } from 'path';
import { vertexLocation } from './config';

// Gemini 2.5 Flash is a thinking model: thinking tokens are consumed before
// the visible output is written. maxOutputTokens controls only the non-thinking
// output budget. When reasoning is more elaborate, a low ceiling causes the
// JSON response to be hard-truncated mid-stream (observed at 1024 in prod).
// 2048 gives comfortable headroom for the full 6-field JSON schema.
const MAX_OUTPUT_TOKENS = 2048;

// Gemini 2.5 Flash is the current GA model on Vertex AI.
// Gemini 3.x Flash is in preview only — upgrade when GA.
// Verify at https://cloud.google.com/vertex-ai/generative-ai/docs/learn/models
const MODEL = 'gemini-2.5-flash';

// Safety settings — BLOCK_ONLY_HIGH across all categories.
// Critical for CatVox: standard violence thresholds would trigger on natural
// feline hunting and play-fighting behaviour.
const SAFETY_SETTINGS = [
  HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
  HarmCategory.HARM_CATEGORY_HARASSMENT,
  HarmCategory.HARM_CATEGORY_HATE_SPEECH,
  HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
].map((category) => ({
  category,
  threshold: HarmBlockThreshold.BLOCK_ONLY_HIGH,
}));

// The machine-enforced output contract lives in code so Gemini on Vertex AI can
// apply it via responseSchema. Field descriptions should stay aligned with
// TRD §4.3 and the behavioral expectations described in docs/systemInstruction.md.
export const ANALYSIS_RESPONSE_SCHEMA: Schema = {
  type: Type.OBJECT,
  description: 'Structured CatVox multimodal cat behavior analysis result.',
  required: [
    'primary_emotion',
    'confidence_score',
    'analysis',
    'persona_type',
    'cat_thought',
    'owner_tip',
  ],
  properties: {
    primary_emotion: {
      type: Type.STRING,
      description: 'Short label naming the cat\'s main observed emotional state in this clip.',
    },
    confidence_score: {
      type: Type.NUMBER,
      format: 'double',
      description:
        'Confidence score from 0.00 to 1.00 inclusive. Use up to two digits after the decimal point when needed to preserve meaningful precision, for example 0.99.',
    },
    analysis: {
      type: Type.STRING,
      description:
        'Two to three sentences of expert feline behavior analysis grounded in the observed video and audio.',
    },
    persona_type: {
      type: Type.STRING,
      description:
        'Exact CatVox persona label that best matches the observed behavior, using the current persona names defined by the system instruction.',
    },
    cat_thought: {
      type: Type.STRING,
      description:
        'First-person inner monologue written in the voice of the selected persona and grounded in the observed behavior.',
    },
    owner_tip: {
      type: Type.STRING,
      description:
        'Practical, actionable advice for the owner based on the observed behavior, using a professional tone when wellbeing is a concern.',
    },
  },
};

export const ANALYSIS_GENERATION_CONFIG: GenerateContentConfig = {
  temperature: 0.7,
  maxOutputTokens: MAX_OUTPUT_TOKENS,
  responseMimeType: 'application/json',
  responseSchema: ANALYSIS_RESPONSE_SCHEMA,
};

// Loaded from docs/systemInstruction.md at build time (copied to assets/ by
// the build script). Edit docs/systemInstruction.md to change the prompt — no
// .ts changes needed unless the machine-enforced response schema also changes.
const SYSTEM_INSTRUCTION = readFileSync(
  join(__dirname, '../assets/systemInstruction.md'),
  'utf-8'
);

/**
 * Calls Vertex AI Gemini with the given GCS video URI.
 * Returns the raw JSON string from the model (not yet parsed).
 */
export async function callGemini(
  projectId: string,
  gcsUri: string,
  mimeType = 'video/quicktime'
): Promise<string> {
  const ai = new GoogleGenAI({
    vertexai: true,
    project: projectId,
    location: vertexLocation(),
    apiVersion: 'v1',
  });

  const response = await ai.models.generateContent({
    model: MODEL,
    contents: [
      {
        role: 'user',
        parts: [
          {
            fileData: {
              fileUri: gcsUri,
              mimeType,
            },
          },
          { text: 'Analyse this cat video and return a JSON result.' },
        ],
      },
    ],
    config: {
      ...ANALYSIS_GENERATION_CONFIG,
      systemInstruction: SYSTEM_INSTRUCTION,
      safetySettings: SAFETY_SETTINGS,
    },
  });

  const candidates = response.candidates;
  const parts = candidates?.[0]?.content?.parts ?? [];
  const finishReason = candidates?.[0]?.finishReason;

  // Gemini 2.5 Flash is a thinking model: parts may include reasoning chunks
  // flagged with `thought: true`. The Gen AI SDK text getter already excludes
  // thought parts and concatenates visible text from the first candidate.
  const text = response.text ?? '';

  if (!text) {
    const summary = JSON.stringify({
      candidateCount: candidates?.length ?? 0,
      finishReason,
      partCount: parts.length,
      partTypes: parts.map(partTypeLabel),
    });
    throw new Error(`Empty response from Vertex AI — ${summary}`);
  }

  return text;
}

function partTypeLabel(part: Part): string {
  if (part.thought) return 'thought';
  if (part.text !== undefined) return 'text';
  if (part.fileData !== undefined) return 'fileData';
  if (part.inlineData !== undefined) return 'inlineData';
  if (part.functionCall !== undefined) return 'functionCall';
  if (part.functionResponse !== undefined) return 'functionResponse';
  return 'unknown';
}
