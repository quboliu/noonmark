import { useCallback, useEffect, useRef, useState } from 'react';
import type { Snapshot } from './types';

type DraftRecord = { key: string; scope: string; revision: string; value: unknown; updated: number };
const DATABASE = 'noonmark-input-drafts';
const TTL = 7 * 24 * 60 * 60 * 1000;
const LIMIT = 100_000;
let connection: Promise<IDBDatabase> | undefined;
function database(): Promise<IDBDatabase> {
  if (!connection) connection = new Promise((resolve, reject) => {
    const opening = indexedDB.open(DATABASE, 1);
    opening.onupgradeneeded = () => opening.result.createObjectStore('drafts', { keyPath: 'key' });
    opening.onsuccess = () => resolve(opening.result);
    opening.onerror = () => reject(new Error('DRAFT_STORAGE_UNAVAILABLE'));
    opening.onblocked = () => reject(new Error('DRAFT_STORAGE_BLOCKED'));
  });
  return connection;
}
async function read<T>(key: string): Promise<(DraftRecord & { value: T }) | undefined> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const request = db.transaction('drafts').objectStore('drafts').get(key);
    request.onsuccess = () => {
      const record = request.result as DraftRecord & { value: T } | undefined;
      resolve(record && record.updated > Date.now() - TTL ? record : undefined);
    };
    request.onerror = () => reject(new Error('DRAFT_READ_FAILED'));
  });
}
async function write(record: DraftRecord): Promise<void> {
  if (new TextEncoder().encode(JSON.stringify(record.value)).byteLength > LIMIT) throw new Error('DRAFT_TOO_LARGE');
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite');
    const store = transaction.objectStore('drafts');
    store.put(record);
    const cursor = store.openCursor();
    cursor.onsuccess = () => {
      const entry = cursor.result;
      if (!entry) return;
      if ((entry.value as DraftRecord).updated < Date.now() - TTL) entry.delete();
      entry.continue();
    };
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(new Error('DRAFT_WRITE_FAILED'));
    transaction.onabort = () => reject(new Error('DRAFT_WRITE_FAILED'));
  });
}
async function remove(key: string): Promise<void> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite');
    transaction.objectStore('drafts').delete(key);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(new Error('DRAFT_DELETE_FAILED'));
  });
}
export function draftScope(snapshot: Snapshot): string {
  return [location.origin, snapshot.instance_id, snapshot.instance_epoch, snapshot.owner_id, snapshot.dataset_id].join('|');
}
export async function clearDrafts(scope: string): Promise<void> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction('drafts', 'readwrite');
    const request = transaction.objectStore('drafts').openCursor();
    request.onsuccess = () => {
      const cursor = request.result;
      if (!cursor) return;
      if ((cursor.value as DraftRecord).scope === scope) cursor.delete();
      cursor.continue();
    };
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(new Error('DRAFT_DELETE_FAILED'));
  });
}
export function useDraft<T>(scope: string, editor: string, revision: string, initial: T) {
  const key = `${scope}|${editor}`;
  const [value, setValue] = useState(initial);
  const [ready, setReady] = useState(false);
  const [storageError, setStorageError] = useState(false);
  const [baseRevision, setBaseRevision] = useState(revision);
  const composing = useRef(false);
  const hasInput = useRef(false);
  const revisionRef = useRef(revision);
  revisionRef.current = revision;
  const current = useRef(value);
  const initialValue = useRef(initial);
  const initialRevision = useRef(revision);
  const queue = useRef<Promise<void>>(Promise.resolve());
  useEffect(() => {
    let active = true;
    setReady(false);
    void read<T>(key).then(record => {
      if (!active) return;
      const restored = record?.value ?? initialValue.current;
      setValue(restored);
      current.current = restored;
      setBaseRevision(record?.revision ?? initialRevision.current);
      hasInput.current = Boolean(record);
    }).catch(() => { if (active) setStorageError(true); }).finally(() => { if (active) setReady(true); });
    return () => { active = false; };
  }, [key]);
  useEffect(() => {
    if (!hasInput.current) {
      setBaseRevision(revision);
      setValue(initial);
      current.current = initial;
    }
  }, [revision]);
  const persist = useCallback((next: T) => {
    queue.current = queue.current.catch(() => {}).then(() => write({ key, scope, revision: baseRevision, value: next, updated: Date.now() })).catch(() => setStorageError(true));
  }, [key, scope, baseRevision]);
  const update = (next: T) => {
    hasInput.current = true;
    current.current = next;
    setValue(next);
    if (!composing.current) persist(next);
  };
  const clear = async (next: T) => {
    current.current = next;
    setValue(next);
    setBaseRevision(revisionRef.current);
    hasInput.current = false;
    await queue.current;
    try { await remove(key); } catch { setStorageError(true); }
  };
  return {
    value, update, clear, ready, storageError, stale: baseRevision !== revision, baseRevision, composing,
    acceptRevision: () => { setBaseRevision(revision); },
    onCompositionStart: () => { composing.current = true; },
    onCompositionEnd: () => { composing.current = false; persist(current.current); },
  };
}
