// Renderer-wide serialization also fences writes from a previous AiChat mount.
let tail: Promise<unknown> = Promise.resolve();
export function queueHistoryOperation<T>(operation: () => Promise<T> | T): Promise<T> {
  const task = tail.catch(() => {}).then(operation);
  tail = task;
  return task;
}
