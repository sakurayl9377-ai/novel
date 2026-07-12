export const iflytekSpeechDefaults = {
  asrProductType: "rtasr",
  asrHostUrls: {
    rtasr: "wss://rtasr.xfyun.cn/v1/ws",
    iat: "wss://iat-api.xfyun.cn/v2/iat",
    spark: "wss://iat-api.xfyun.cn/v2/iat",
  },
  ttsHostUrl: "wss://tts-api.xfyun.cn/v2/tts",
};

export function defaultAsrHostUrl(productType) {
  return (
    iflytekSpeechDefaults.asrHostUrls[productType] ||
    iflytekSpeechDefaults.asrHostUrls[iflytekSpeechDefaults.asrProductType]
  );
}
