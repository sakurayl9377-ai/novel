export interface SessionUser {
  id: number;
  email: string;
  nickname: string;
  role: string;
  status: string;
  avatarUrl?: string;
}

export interface AuthResponse {
  token: string;
  user: SessionUser;
}
