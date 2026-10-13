import type { Command, Receipt, Snapshot } from './types';

export class APIError extends Error {
  constructor(public code: string, public status: number) { super(code); }
}
export async function request<T>(path: string, token?: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'omit', cache: 'no-store', signal: signal ?? AbortSignal.timeout(20_000),
  });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new APIError(error.code ?? error.error?.code ?? 'REQUEST_FAILED', response.status);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}
export const getSnapshot = (token: string) => request<Snapshot>('/api/v1/snapshot', token);
export const submit = (token: string, command: Command) => request<Receipt>('/api/v1/commands', token, command);
export const getReceipt = (token: string, id: string) => request<Receipt>(`/api/v1/commands/${encodeURIComponent(id)}`, token);

const messages: Record<string, string> = {
  AUTH_REQUIRED: '登录已失效，请重新登录。输入草稿会保留。',
  SESSION_REVOKED: '这次登录已被撤销，请重新登录。',
  INVALID_CREDENTIALS: '密码不正确，请重试。',
  INVALID_PASSWORD: '密码不正确，请重试。',
  VERSION_CONFLICT: '另一台设备已经修改了这项内容。已刷新最新状态，你的输入仍然保留，请核对后再次提交。',
  DAY_LOCKED: '这一天已经结束，历史轨迹不能再修改。你仍可补写复盘。',
  INSTANCE_CHANGED: '实例已恢复或发生变更，请重新登录。旧输入不会自动提交。',
  DATASET_INACTIVE: '当前资料已被替换，请重新登录。旧输入不会自动提交。',
  SCHEMA_UNSUPPORTED: '此页面版本与服务器不兼容，请刷新页面。',
  STORAGE_FULL: '服务器空间不足，内容尚未保存。请联系实例管理员。',
  BUSY: '服务器正忙，请稍后重试。',
  MAINTENANCE: '实例正在维护，暂时不能提交。',
  RATE_LIMITED: '操作太频繁，请稍后重试。',
  INVALID_DATE: '请选择有效日期；不能将任务安排到已经结束的日子。',
  FUTURE_DAY: '未来的任务还不能完成，请在安排的当天处理。',
  OPEN_SUBTASKS: '还有未完成的子任务，请先完成或废弃它们。',
  INVALID_TRANSITION: '这项操作不适用于任务的当前状态。已保留输入，请核对最新轨迹。',
  CHAIN_ABANDONED: '这条任务链已经废弃，请先重新激活。',
  WEIGHTED_PROGRESS: '有子任务时，进度由子任务权重计算。',
  INVALID_REQUEST: '请求内容未通过校验，请刷新页面后重试。',
  STORAGE_UNAVAILABLE: '实例暂时无法读取资料，请稍后重试。',
  COMMAND_UNSUPPORTED: '此页面与实例支持的操作不一致，请刷新页面。',
  INVALID_COMMAND: '这项操作不适用于当前状态，请刷新后核对。',
  INVALID_INPUT: '请检查输入内容和日期。',
  VALIDATION_FAILED: '请检查输入内容和日期。',
  NOT_FOUND: '内容已不存在，请刷新页面。',
  INVARIANT_VIOLATION: '服务器拒绝了会改变历史的操作，资料没有被修改。',
};
export function errorMessage(error: unknown): string {
  if (error instanceof APIError) return messages[error.code] ?? `操作未完成（${error.code}），请核对最新状态后重试。`;
  return '暂时无法连接实例。输入仍在这里，请恢复连接后核对提交结果。';
}
