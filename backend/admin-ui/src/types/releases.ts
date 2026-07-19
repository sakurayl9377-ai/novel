export type ReleaseIntegrityStatus = 'unconfigured' | 'blocked' | 'warning' | 'ready';

export interface ReleaseManifest {
  versionName: string;
  versionCode: number;
  apkUrl: string;
  sha256: string;
  actualSha256: string;
  force: boolean;
  notes: string[];
}

export interface ReleaseHistoryItem {
  fileName: string;
  versionName: string;
  versionCode: number;
  force: boolean;
  sha256: string;
  modifiedAt: string;
}

export interface ReleaseBackup {
  name: string;
  modifiedAt: string;
}

export interface ReleaseWorkbenchResponse {
  configured: boolean;
  generatedAt: string;
  integrityStatus: ReleaseIntegrityStatus;
  checks: {
    manifest: { valid: boolean; status: string; reason: string } | 'missing';
    artifact: string;
    checksum: string;
  };
  current: ReleaseManifest | null;
  apk: {
    exists: boolean;
    sizeBytes: number;
    modifiedAt: string;
  };
  history: ReleaseHistoryItem[];
  backups: ReleaseBackup[];
}
