# File: scripts/check_streams.py
"""
File path: scripts/check_streams.py

用途：
- 保持原格式（txt、m3u、#EXTINF 分组/注释/顺序）
- 并发检测直播源（http/https 使用 aiohttp HEAD 优先，rtsp/udp 等使用 ffprobe）
- 剔除失效源，生成新文件（临时写入 -> 原子替换）
- 设计用于 GitHub Actions ubuntu-latest（需安装 ffmpeg）
"""

from __future__ import annotations
import argparse
import asyncio
import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from typing import List, Optional, Tuple
import time

# Third-party libs
# Ensure installed: aiohttp, tqdm
import aiohttp
from tqdm.asyncio import tqdm_asyncio
from tqdm import tqdm

# --- Configurable defaults ---
DEFAULT_HTTP_CONCURRENCY = 200
DEFAULT_FFPROBE_CONCURRENCY = 40
DEFAULT_HTTP_TIMEOUT = 6.0  # seconds
DEFAULT_FFPROBE_TIMEOUT = 10.0  # seconds
FFPROBE_CMD = shutil.which("ffprobe") or "ffprobe"
# -------------------------------

URL_RE = re.compile(r'(?P<url>(?:https?|rtsp|rtmp|udp)://\S+)', re.I)

@dataclass
class Entry:
    """Represents a block of original lines that corresponds to 0 or 1 stream URL."""
    original_lines: List[str]  # includes trailing newlines removed (we'll re-add '\n' when writing)
    url: Optional[str]  # extracted url or None
    index: int  # original order index

@dataclass
class Result:
    url: str
    alive: bool
    method: str  # 'http-head' or 'ffprobe'
    latency: float
    msg: Optional[str] = None

# -----------------------
# File parsing utilities
# -----------------------
def parse_playlist_lines(lines: List[str]) -> List[Entry]:
    """
    Parse raw lines into entries.
    Rules:
    - For M3U-like (#EXTINF present): group EXTINF + next non-empty non-comment line (url) as one Entry.
    - For plain text: each non-comment line that looks like URL is an Entry.
    - Comment lines or non-url lines are standalone entries with url=None and kept as-is.
    """
    entries: List[Entry] = []
    i = 0
    idx = 0
    n = len(lines)
    while i < n:
        line = lines[i].rstrip("\n")
        if line.strip().startswith("#EXTINF"):
            # gather EXTINF and any following comment lines until url line
            block = [line]
            j = i + 1
            # collect subsequent comment lines possibly (e.g., group-title etc)
            while j < n and lines[j].strip().startswith("#") and not URL_RE.search(lines[j]):
                block.append(lines[j].rstrip("\n"))
                j += 1
            # next non-empty line is expected to be url
            url = None
            if j < n and lines[j].strip() != "":
                block.append(lines[j].rstrip("\n"))
                m = URL_RE.search(lines[j])
                url = m.group("url") if m else (lines[j].strip() if looks_like_url(lines[j]) else None)
                j += 1
            entries.append(Entry(original_lines=block, url=url, index=idx))
            idx += 1
            i = j
        else:
            # not EXTINF
            # If line is a comment or empty -> standalone entry
            if line.strip().startswith("#") or line.strip() == "":
                entries.append(Entry(original_lines=[line], url=None, index=idx))
                idx += 1
                i += 1
            else:
                # Non-comment, non-empty: could be a bare URL or text
                m = URL_RE.search(line)
                if m:
                    entries.append(Entry(original_lines=[line], url=m.group("url"), index=idx))
                else:
                    # Maybe bare url without protocol? keep as-is but url=None
                    entries.append(Entry(original_lines=[line], url=None, index=idx))
                idx += 1
                i += 1
    return entries

def looks_like_url(s: str) -> bool:
    s = s.strip()
    return bool(URL_RE.search(s))

# -----------------------
# Detection utilities
# -----------------------
async def probe_http(session: aiohttp.ClientSession, url: str, timeout: float) -> Tuple[bool, float, str]:
    """Try HEAD, fallback to GET if HEAD not allowed. Return (alive, latency, msg)."""
    start = time.perf_counter()
    try:
        async with session.head(url, allow_redirects=True, timeout=timeout) as resp:
            status = resp.status
            latency = time.perf_counter() - start
            if 200 <= status < 400:
                return True, latency, f"HTTP HEAD {status}"
            # some servers disallow HEAD -> 405 or similar
            if status in (405, 501):
                # fallback to GET
                pass
            else:
                return False, latency, f"HTTP HEAD {status}"
    except aiohttp.ClientResponseError as e:
        return False, time.perf_counter() - start, f"HTTP HEAD error: {e}"
    except (aiohttp.ServerTimeoutError, asyncio.TimeoutError) as e:
        return False, time.perf_counter() - start, f"HTTP HEAD timeout"
    except Exception as e:
        # fallback to GET
        pass

    # HEAD failed or refused: try GET (with small range)
    start2 = time.perf_counter()
    try:
        async with session.get(url, allow_redirects=True, timeout=timeout) as resp:
            status = resp.status
            latency = time.perf_counter() - start2
            if 200 <= status < 400:
                return True, latency, f"HTTP GET {status}"
            else:
                return False, latency, f"HTTP GET {status}"
    except (aiohttp.ServerTimeoutError, asyncio.TimeoutError):
        return False, time.perf_counter() - start2, "HTTP GET timeout"
    except Exception as e:
        return False, time.perf_counter() - start2, f"HTTP GET error: {e}"

async def probe_ffprobe(url: str, timeout: float) -> Tuple[bool, float, str]:
    """
    Use ffprobe to probe a stream.
    Returns (alive, latency, message)
    """
    # Prepare command: keep it quiet; set rw_timeout in microseconds
    timeout_us = int(timeout * 1_000_000)
    cmd = [
        FFPROBE_CMD,
        "-v", "error",
        "-rw_timeout", str(timeout_us),
        "-timeout", str(timeout_us),  # some builds support -timeout
        "-i", url,
        "-show_streams",
        "-print_format", "json"
    ]
    # Some ffprobe builds require quote-wrapping; using list avoids shell.
    start = time.perf_counter()
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
    except FileNotFoundError:
        return False, 0.0, "ffprobe-not-found"
    try:
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout + 2)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            return False, time.perf_counter() - start, "ffprobe-timeout"
        rc = proc.returncode
        latency = time.perf_counter() - start
        if rc == 0 and stdout:
            # try to minimally validate JSON or content
            s = stdout.decode(errors="ignore").strip()
            if s:
                return True, latency, "ffprobe-ok"
            return False, latency, "ffprobe-no-streams"
        else:
            msg = stderr.decode(errors="ignore").strip()
            return False, latency, f"ffprobe-rc{rc}:{msg[:200]}"
    except Exception as e:
        try:
            proc.kill()
        except Exception:
            pass
        return False, time.perf_counter() - start, f"ffprobe-err:{e}"

# -----------------------
# Orchestration
# -----------------------
async def check_url(url: str,
                    session: aiohttp.ClientSession,
                    http_timeout: float,
                    ffprobe_timeout: float,
                    http_semaphore: asyncio.Semaphore,
                    ffprobe_semaphore: asyncio.Semaphore) -> Result:
    """Decide which method to use based on scheme, run probe, return Result."""
    scheme = url.split(":", 1)[0].lower()
    # prefer http head for http(s)
    if scheme in ("http", "https"):
        async with http_semaphore:
            t0 = time.perf_counter()
            alive, latency, msg = await probe_http(session, url, timeout=http_timeout)
            elapsed = time.perf_counter() - t0
            if alive:
                return Result(url=url, alive=True, method="http-head", latency=latency, msg=msg)
            # fallback to ffprobe if HEAD/GET inconclusive or server demands
    # For non-http or fallback:
    async with ffprobe_semaphore:
        t0 = time.perf_counter()
        alive, latency, msg = await probe_ffprobe(url, timeout=ffprobe_timeout)
        elapsed = time.perf_counter() - t0
        method = "ffprobe"
        return Result(url=url, alive=alive, method=method, latency=latency, msg=msg)

def build_output_from_entries(entries: List[Entry], alive_set: set, keep_empty_groups: bool) -> List[str]:
    """
    Build output lines from entries. If an entry has url and url not in alive_set -> remove it.
    For m3u #EXTINF cases, the EXTINF line is inside the same Entry; removing that whole entry is desired.
    """
    out_lines: List[str] = []
    for e in entries:
        if e.url is None:
            # keep comment/blank lines or non-url lines
            out_lines.extend([ln + ("\n" if not ln.endswith("\n") else "") for ln in e.original_lines])
        else:
            if e.url in alive_set:
                out_lines.extend([ln + ("\n" if not ln.endswith("\n") else "") for ln in e.original_lines])
            else:
                # removed: do nothing (drop the entry)
                # But if it's an m3u and user wants to keep empty groups, we could insert a comment - controlled by flag
                if keep_empty_groups:
                    out_lines.append(f"# REMOVED_DEAD_STREAM: {e.url}\n")
    return out_lines

async def worker_check_all(entries: List[Entry],
                           http_concurrency: int,
                           ffprobe_concurrency: int,
                           http_timeout: float,
                           ffprobe_timeout: float) -> Tuple[List[Result], List[str]]:
    """
    Check all urls in entries concurrently.
    Returns list of results and list of errors/warnings (log).
    """
    urls = []
    url_to_entries = {}
    for e in entries:
        if e.url:
            urls.append(e.url)
            url_to_entries.setdefault(e.url, []).append(e)

    # deduplicate URLs to avoid re-checking identical URLs
    unique_urls = list(dict.fromkeys(urls))

    connector = aiohttp.TCPConnector(limit=0)  # rely on semaphore to limit concurrency
    timeout = aiohttp.ClientTimeout(total=None)
    results: List[Result] = []
    warnings: List[str] = []

    http_sem = asyncio.Semaphore(http_concurrency)
    ffprobe_sem = asyncio.Semaphore(ffprobe_concurrency)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        # create tasks
        sem_tasks = []
        # tqdm to show progress
        tasks = []
        for url in unique_urls:
            tasks.append(check_url(url, session, http_timeout, ffprobe_timeout, http_sem, ffprobe_sem))

        # run in bounded concurrency via asyncio.gather with semaphore inside functions
        # Using tqdm_asyncio to display progress
        for coro in tqdm_asyncio.as_completed(tasks, total=len(tasks), desc="Probing"):
            try:
                res = await coro
            except Exception as e:
                # convert exceptions into Result failure
                res = Result(url="unknown", alive=False, method="error", latency=0.0, msg=str(e))
                warnings.append(f"probe-error: {e}")
            results.append(res)

    return results, warnings

# -----------------------
# CLI and main
# -----------------------
def read_file_lines(path: str) -> List[str]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.readlines()

def write_atomic(path: str, lines: List[str]) -> None:
    dirpath = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix="tmp_streamcheck_", dir=dirpath, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write(ln)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass

def generate_report(results: List[Result], outpath: Optional[str]) -> None:
    data = [r.__dict__ for r in results]
    if outpath:
        with open(outpath, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

def summarize_results(results: List[Result]) -> Tuple[int,int]:
    alive = sum(1 for r in results if r.alive)
    total = len(results)
    return alive, total

def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Detect live-stream sources and remove dead ones (preserve format/order).")
    p.add_argument("--input", "-i", required=True, help="Input playlist/file (txt or m3u)")
    p.add_argument("--output", "-o", required=True, help="Output cleaned file")
    p.add_argument("--http-concurrency", type=int, default=DEFAULT_HTTP_CONCURRENCY, help="Concurrency for HTTP checks")
    p.add_argument("--ffprobe-concurrency", type=int, default=DEFAULT_FFPROBE_CONCURRENCY, help="Concurrency for ffprobe checks")
    p.add_argument("--http-timeout", type=float, default=DEFAULT_HTTP_TIMEOUT, help="Timeout (s) for HTTP checks")
    p.add_argument("--ffprobe-timeout", type=float, default=DEFAULT_FFPROBE_TIMEOUT, help="Timeout (s) for ffprobe checks")
    p.add_argument("--report", default=None, help="Optional JSON report path")
    p.add_argument("--keep-empty-groups", action="store_true", help="If true, insert comment markers for removed streams instead of dropping silently")
    return p

def is_m3u_like(lines: List[str]) -> bool:
    # simple heuristic: any #EXTM3U or #EXTINF present
    for ln in lines[:20]:
        if ln.strip().startswith("#EXTM3U") or ln.strip().startswith("#EXTINF"):
            return True
    return False

async def main_async(args):
    lines = read_file_lines(args.input)
    entries = parse_playlist_lines(lines)
    print(f"Parsed {len(entries)} entries from {args.input}")

    results, warnings = await worker_check_all(
        entries,
        http_concurrency=args.http_concurrency,
        ffprobe_concurrency=args.ffprobe_concurrency,
        http_timeout=args.http_timeout,
        ffprobe_timeout=args.ffprobe_timeout
    )

    # Map results by url
    url_status = {r.url: r for r in results if r.url}
    alive_set = {r.url for r in results if r.alive and r.url}

    alive_count, total_count = summarize_results(results)
    print(f"Checked {total_count} unique urls: alive={alive_count} dead={total_count-alive_count}")

    # Build output
    out_lines = build_output_from_entries(entries, alive_set, args.keep_empty_groups)

    # if original file had EXTM3U header, ensure it's kept
    if is_m3u_like(lines) and (not out_lines or not any(l.strip().startswith("#EXTM3U") for l in out_lines)):
        out_lines.insert(0, "#EXTM3U\n")

    write_atomic(args.output, out_lines)
    print(f"Wrote cleaned playlist to {args.output}")

    if args.report:
        generate_report(results, args.report)
        print(f"Wrote report to {args.report}")

    if warnings:
        print("Warnings:")
        for w in warnings[:10]:
            print(" -", w)
    # exit code: 0
    return 0

def main():
    parser = build_argparser()
    args = parser.parse_args()
    try:
        rc = asyncio.run(main_async(args))
        sys.exit(rc)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
