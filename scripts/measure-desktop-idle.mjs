#!/usr/bin/env node
// Observe an existing process. Never launch, hide, focus, or signal an application.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { platform, release } from "node:os";
import { performance } from "node:perf_hooks";
import { setTimeout as delay } from "node:timers/promises";

const args = process.argv.slice(2);
const usage = "node scripts/measure-desktop-idle.mjs --pid <existing-pid> [--seconds 60] [--interval-ms 1000] [--output report.json]";
if (args.includes("--help")) { console.log(usage); process.exit(0); }
const options = {};
for (let i = 0; i < args.length; i += 2) {
  if (!["--pid", "--seconds", "--interval-ms", "--output"].includes(args[i]) || !args[i + 1] || args[i + 1].startsWith("--")) throw new Error(usage);
  options[args[i].slice(2)] = args[i + 1];
}
const pid = Number(options.pid);
const seconds = Number(options.seconds ?? 60);
const interval = Number(options["interval-ms"] ?? 1000);
if (!Number.isSafeInteger(pid) || pid < 1 || !Number.isFinite(seconds) || seconds < 1 || seconds > 3600 || !Number.isFinite(interval) || interval < 250 || interval > 10000) throw new Error(usage);
if (!["darwin", "linux"].includes(platform())) throw new Error("This observer requires macOS or Linux ps.");

function cpuSeconds(value) {
  const [days, clock] = value.includes("-") ? value.split("-") : ["0", value];
  return Number(days) * 86400 + clock.split(":").reduce((total, part) => total * 60 + Number(part), 0);
}
function snapshot() {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,time=,rss=,comm="], { encoding: "utf8", timeout: 5000, maxBuffer: 8 * 1024 * 1024 })
    .trim().split("\n").flatMap((line) => {
      const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(.+)$/);
      return match ? [{ pid: Number(match[1]), parent: Number(match[2]), cpuSeconds: cpuSeconds(match[3]), rssKiB: Number(match[4]), executable: match[5] }] : [];
    });
  const root = rows.find((row) => row.pid === pid);
  if (!root) throw new Error(`Process ${pid} exited or is unavailable; no replacement will be started.`);
  const included = new Set([pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) if (included.has(row.parent) && !included.has(row.pid)) { included.add(row.pid); changed = true; }
  }
  return { at: performance.now(), root: root.executable, rows: rows.filter((row) => included.has(row.pid)) };
}
const initial = snapshot();
const samples = [];
let previous = initial;
while (performance.now() - initial.at < seconds * 1000) {
  await delay(Math.min(interval, Math.max(1, seconds * 1000 - (performance.now() - initial.at))));
  const next = snapshot();
  if (next.root !== initial.root) throw new Error("Process identity changed; measurement aborted.");
  const elapsed = (next.at - previous.at) / 1000;
  let cpuDelta = 0;
  for (const row of next.rows) {
    const prior = previous.rows.find((candidate) => candidate.pid === row.pid && candidate.executable === row.executable);
    if (prior) cpuDelta += Math.max(0, row.cpuSeconds - prior.cpuSeconds);
  }
  samples.push({ elapsedMs: Math.round(next.at - initial.at), cpuPercentOneCore: cpuDelta / elapsed * 100, rssMiB: next.rows.reduce((total, row) => total + row.rssKiB, 0) / 1024, processCount: next.rows.length, intervalMs: next.at - previous.at });
  previous = next;
}
const report = {
  schemaVersion: 1, recordedAt: new Date().toISOString(), platform: platform(), osRelease: release(), pid, executable: initial.root,
  durationMs: samples.at(-1).elapsedMs,
  meanCpuPercentOneCore: samples.reduce((total, row) => total + row.cpuPercentOneCore * row.intervalMs, 0) / samples.reduce((total, row) => total + row.intervalMs, 0),
  maxRssMiB: Math.max(...samples.map((row) => row.rssMiB)), samples,
  boundaries: ["Observes the existing PID and current descendants only; never controls the app or server.", "Externally parented WebKit/XPC services are not attributed. RSS is not physical footprint and shared pages may be counted more than once.", "CPU from processes that start or exit between samples is not fully captured. Visibility, focus, build identity, and idle conditions must be recorded separately.", "Development-process observations do not pass packaged performance gates."],
};
const json = JSON.stringify(report, null, 2) + "\n";
if (options.output) writeFileSync(options.output, json, { flag: "wx", mode: 0o600 });
else process.stdout.write(json);
