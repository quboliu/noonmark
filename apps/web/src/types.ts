export interface Chain {
  id: string;
  definition_id: string;
  state: 'active' | 'abandoned';
  location: 'pool' | 'trace' | 'followup' | 'completed' | 'abandoned';
  revision: string;
  created_at: string;
  updated_at: string;
}
export interface Definition {
  id: string;
  chain_id: string;
  version: number;
  planned_subtasks: { id: string; lineage_id: string; title: string; difficulty: 'simple' | 'medium' | 'hard'; position: number }[];
  title: string;
  description: string;
  created_at: string;
  updated_at: string;
}
export type TraceStatus = 'pending' | 'completed' | 'unfinished' | 'deferred' | 'changed' | 'returnedToPool' | 'cancelledDraft' | 'abandoned';
export interface Trace {
  id: string;
  chain_id: string;
  definition_id: string;
  date: string;
  status: TraceStatus;
  priority: number;
  continuation_seq: number;
  description: string;
  carried_from_trace_id?: string;
  progress_floor: number;
  manual_progress: number;
  progress: number;
  created_at: string;
  updated_at: string;
  completed_at?: string;
  settled_at?: string;
}
export interface Subtask {
  id: string;
  trace_id: string;
  lineage_id: string;
  title: string;
  difficulty: 'simple' | 'medium' | 'hard';
  status: 'pending' | 'completed' | 'unfinished' | 'deferred' | 'abandoned' | 'cancelledDraft';
  position: number;
  created_at: string;
  updated_at: string;
}
export interface Day {
  date: string;
  revision: string;
  locked_at?: string;
  summary: string;
  unfinished_reason: string;
  tomorrow_note: string;
}
export interface Idea {
  id: string;
  body: string;
  revision: string;
  pinned_at?: string;
  deleted_at?: string;
  created_at: string;
  updated_at: string;
}
export interface Snapshot {
  schema_version: number;
  instance_id: string;
  instance_epoch: string;
  dataset_id: string;
  owner_id: string;
  sequence: string;
  frontier_bits: string;
  today: string;
  timezone: string;
  chains: Chain[];
  definitions: Definition[];
  traces: Trace[];
  subtasks: Subtask[];
  days: Day[];
  ideas: Idea[];
}
export interface Command {
  instance_id: string;
  instance_epoch: string;
  dataset_id: string;
  command_id: string;
  schema_version: 1;
  type: string;
  expected_revision: string;
  payload: Record<string, unknown>;
}
export interface Receipt {
  command_id: string;
  status: 'committed';
  sequence: string;
  entity_id: string;
  mutation_bits: string;
}
export type Execute = (type: string, revision: string, payload: Record<string, unknown>) => Promise<boolean>;
