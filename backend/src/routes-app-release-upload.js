import {
  appReleaseChunkBytes,
  appReleaseUploadStatus,
  finalizeAppReleaseUpload,
  releaseTokenFromAuthorization,
  saveAppReleasePart,
} from './app-release-upload.js';

export async function appReleaseUploadRoutes(app) {
  app.get('/internal/app-release/status', async (request) => {
    return appReleaseUploadStatus({ token: requestToken(request) });
  });

  app.put(
    '/internal/app-release/chunks/:index',
    { bodyLimit: appReleaseChunkBytes + 512 * 1024 },
    async (request) => {
      const upload = await request.file({
        limits: { files: 1, fields: 0, parts: 1, fileSize: appReleaseChunkBytes },
      });
      if (!upload || upload.fieldname !== 'apk') {
        const error = new Error('app_release_part_missing');
        error.publicCode = 'app_release_part_missing';
        error.statusCode = 400;
        throw error;
      }
      return saveAppReleasePart({
        token: requestToken(request),
        index: request.params?.index,
        partCount: request.headers['x-release-part-count'],
        declaredSha256: request.headers['x-release-part-sha256'],
        stream: upload.file,
      });
    },
  );

  app.post('/internal/app-release/finalize', async (request) => {
    return finalizeAppReleaseUpload({ token: requestToken(request) });
  });
}

function requestToken(request) {
  return releaseTokenFromAuthorization(request.headers.authorization);
}
