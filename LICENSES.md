# Third-party software used by the kit

None of these are stored in the git repository. `tools/fetch_assets.py` downloads them from their official
release pages into `assets/` (USB stick and release zips only). Versions are pinned in that script.

| Tool | Licence | Source |
|---|---|---|
| smartctl (smartmontools 7.4) | GPL-2.0-or-later (COPYING.txt shipped next to it) | https://www.smartmontools.org/ , source: https://sourceforge.net/projects/smartmontools/files/ |
| FFmpeg 8.1 (BtbN gpl-shared build, includes x264) | GPL-3.0 | https://github.com/BtbN/FFmpeg-Builds , source: https://ffmpeg.org/download.html |
| llama.cpp llama-bench (b12776) | MIT | https://github.com/ggml-org/llama.cpp |
| Qwen2.5-0.5B-Instruct GGUF Q4_K_M | Apache-2.0 | https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF |

The kit's own scripts: MIT.
