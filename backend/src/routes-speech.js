import { synthesizeIflytek, transcribeChatAudio } from "./speech-service.js";
import { enforceRateLimits } from "./rate-limit.js";
import { badRequest, requiredString } from "./validators.js";

export async function speechRoutes(app) {
  app.post(
    "/speech/tts",
    { preHandler: app.authRequired },
    async (request, reply) => {
      const limited = enforceRateLimits(request, reply, [
        {
          scope: "speech-tts-user",
          key: request.user.id,
          limit: 30,
          windowMs: 60_000,
          error: "speech_tts_rate_limited",
        },
        {
          scope: "speech-tts-ip",
          key: request.ip,
          limit: 60,
          windowMs: 60_000,
          error: "speech_tts_rate_limited",
        },
      ]);
      if (limited) return limited;
      const body = request.body || {};
      const text = requiredString(body.text, "text", 180);
      try {
        const audio = await synthesizeIflytek(text, {
          voice: body.voice,
          rate: body.rate,
          volume: body.volume,
          pitch: body.pitch,
        });
        return reply.type("audio/mpeg").send(audio);
      } catch (error) {
        const code = String(error.message || "speech_tts_failed");
        if (code === "speech_tts_timeout") {
          throw speechServiceError(code, 504);
        }
        if (code === "speech_tts_connection_closed" || error?.code) {
          throw speechServiceError("speech_tts_connection_failed", 502);
        }
        throw badRequest(code);
      }
    },
  );

  app.post(
    "/speech/transcribe",
    { preHandler: app.authRequired },
    async (request) => {
      const mediaUrl = requiredString(request.body?.mediaUrl, "mediaUrl", 1000);
      if (!/^https?:\/\//i.test(mediaUrl)) {
        throw badRequest("speech_audio_url_invalid");
      }
      try {
        const text = await transcribeChatAudio(mediaUrl, {
          userId: request.user.id,
        });
        return { ok: true, text };
      } catch (error) {
        const message = String(error.message || "");
        if (message.includes("Unexpected server response: 400")) {
          throw badRequest("speech_asr_bad_request");
        }
        throw badRequest(message || "speech_asr_failed");
      }
    },
  );
}

function speechServiceError(code, statusCode) {
  const error = new Error(code);
  error.statusCode = statusCode;
  return error;
}
