import { Router, Request, Response, NextFunction } from 'express';
import { execSync } from 'child_process';
import { readFileSync, readdirSync } from 'fs';
import { requireHost } from '../middleware/auth';

export const phoneRouter = Router();

/**
 * GET /v1/phone/stats — host health snapshot for the Android phone running
 * the control plane (Termux-AGT, 2026-10-10). Authenticated (host or agent
 * token). Returns memory, disk, CPU temperature (max plausible thermal
 * zone), and timestamp. The watchdog polls this and alerts on
 * CPU > 70C, RAM > 90%, disk > 90%.
 */
phoneRouter.get(
  '/stats',
  requireHost,
  (req: Request, res: Response, next: NextFunction) => {
    try {
      const meminfo = readFileSync('/proc/meminfo', 'utf8');
      const total = Number(/MemTotal:\s+(\d+)/.exec(meminfo)?.[1] ?? 0) * 1024;
      const avail = Number(/MemAvailable:\s+(\d+)/.exec(meminfo)?.[1] ?? 0) * 1024;

      // CPU temperature: scan thermal zones, take the max plausible reading.
      let cpuTempC: number | null = null;
      try {
        for (const zone of readdirSync('/sys/class/thermal')) {
          if (!zone.startsWith('thermal_zone')) continue;
          const raw = Number(
            readFileSync(`/sys/class/thermal/${zone}/temp`, 'utf8').trim(),
          );
          if (!Number.isFinite(raw) || raw <= 0) continue;
          const c = raw > 1000 ? raw / 1000 : raw; // millidegrees vs degrees
          if (c > 0 && c < 120 && (cpuTempC === null || c > cpuTempC)) {
            cpuTempC = Math.round(c * 10) / 10;
          }
        }
      } catch {
        // thermal zones may be unreadable; leave null
      }

      // Disk: read /proc/mounts is overkill; use the data dir's statvfs
      // equivalent via a df-style parse of /proc/self/mountinfo is complex —
      // instead report via the root filesystem from /proc/diskstats-free
      // approach: parse `df -k /` output through exec is avoided in-request;
      // use statfs through /proc is not available, so shell out once.
      let diskPct: number | null = null;
      try {
        const out = execSync('df -k /data 2>/dev/null || df -k /', {
          encoding: 'utf8',
          timeout: 5000,
        });
        const m = out.split('\n')[1]?.match(/(\d+)%/);
        if (m) diskPct = Number(m[1]);
      } catch {
        // leave null
      }

      res.json({
        ts: new Date().toISOString(),
        mem: {
          total_bytes: total,
          available_bytes: avail,
          used_pct:
            total > 0
              ? Math.round(((total - avail) / total) * 1000) / 10
              : null,
        },
        cpu_temp_c: cpuTempC,
        disk_used_pct: diskPct,
      });
    } catch (err) {
      next(err);
    }
  },
);
