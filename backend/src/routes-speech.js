import { transcribeChatAudio } from "./speech-service.js";
import { badRequest, requiredString } from "./validators.js";

export async function speechRoutes(app) {
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
