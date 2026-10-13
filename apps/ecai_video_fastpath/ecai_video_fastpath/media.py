"""Safe, bounded ffprobe/ffmpeg operations (argv-only; no shell)."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path


class MediaError(ValueError):
    pass


def probe(path: Path, ffprobe: str, limit: int) -> dict:
    try:
        run = subprocess.run([ffprobe, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", str(path)],
                             capture_output=True, text=True, timeout=25, check=True)
        info = json.loads(run.stdout)
        stream = next(x for x in info["streams"] if x.get("codec_type") == "video")
        # Do not label a Matroska or AVI upload as an MP4 simply because it has an .mp4 filename.
        if "mp4" not in info["format"].get("format_name", "").split(","):
            raise MediaError("Only genuine MP4 containers are supported")
        duration = float(info["format"]["duration"])
        if not 0 < duration <= limit:
            raise MediaError("Video duration outside configured limit")
        if int(stream["width"]) < 16 or int(stream["height"]) < 16:
            raise MediaError("Video dimensions invalid")
        return {"duration_seconds": round(duration, 3), "width": int(stream["width"]),
                "height": int(stream["height"]), "codec": str(stream["codec_name"])}
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, StopIteration, TypeError) as exc:
        raise MediaError(f"Not an accepted video: {exc}") from exc


def render_variant(source: Path, output: Path, operation: str, params: dict, ffmpeg: str, timeout: int,
                   scratch_dir: Path) -> None:
    if operation == "caption":
        caption = params["text"]
        text_path = scratch_dir / "caption.txt"
        text_path.write_text(caption, encoding="utf-8")
        # textfile prevents user text from being interpreted as filter syntax.
        filter_arg = (f"drawtext=textfile={text_path}:fontcolor=white:fontsize=32:"
                      "x=(w-text_w)/2:y=h-text_h-36:box=1:boxcolor=black@0.65:boxborderw=12")
        args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                "-vf", filter_arg, "-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", str(output)]
    elif operation == "trim":
        args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", str(params["start_seconds"]),
                "-to", str(params["end_seconds"]), "-i", str(source), "-map", "0:v:0", "-map", "0:a?",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", str(output)]
    else:
        raise MediaError("Unsupported rendering operation")
    try:
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise MediaError(f"Renderer error: {exc}") from exc
    if proc.returncode or not output.is_file() or output.stat().st_size == 0:
        raise MediaError("Renderer failed: " + proc.stderr.decode("utf-8", "replace")[-600:])
