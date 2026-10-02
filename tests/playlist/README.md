# Playlist stepping tests

These scripts drive a built IINA through its menus, keyboard and scroll events and read the result
back from mpv over its IPC socket and from IINA's log. They run on Glebs-Mac-Mini only: they launch
and script the app.

## Setup on Glebs-Mac-Mini

- This directory is copied to a directory of its own on the Mini; each script finds the others and
  the compiled helpers next to it.
- The build under test is installed at `/Users/asher/Projects/Deployment/IINA/IINA.app`.
- Test media is in `/Users/asher/Projects/TestMedia-iina`: eight short clips in `review`
  (`clip01.mp4` to `clip08.mp4`) and three long files in `long` (`long01.mp4` to `long03.mp4`).
  `mkmany.py` builds the 10000-file folder `many` from the clips. `frag` holds three fragmented MP4s
  that end in an `mfra` index (`frag-01m.mp4`, `frag-34m.mp4`, `frag-62m.mp4`), from which
  `fragstep_media.sh` builds the folders `fragstep.sh` opens.
- IINA is configured with an mpv IPC socket at `/tmp/iina-mpv.sock` and logging enabled.
- `gesture.swift`, `scroll.swift`, `tcc.swift`, `axctl.swift`, `axmenu.swift` and `keys.swift` are
  compiled with `swiftc` into `gesture`, `scroll`, `tcc`, `axctl`, `axmenu` and `keys`. `gesture`,
  `axctl`, `axmenu` and `keys` post events or press menu items and need the Accessibility
  permission. Menus are pressed with `axmenu` and keys with `keys` rather than through System
  Events, because Apple events to System Events from a process started over ssh wait for a consent
  prompt.

## Cases

| Requirement | Script |
| --- | --- |
| Step resumes, step at the last entry | `step2.sh` (T1, T3) |
| Pause given with a step holds | `step2.sh` (T2), `step3.sh <delay>` |
| Folder playlist order | `assembly.sh <opened-file>` (precedence) |
| Folder playlist completeness | `assembly.sh <opened-file>`, `assembly_restart.py` |
| Scroll boundary and play state | `scroll.sh`, `scroll2.sh` |
| Thumbnail cancellation | `thumbcancel.sh [delay]` |
| Thumbnail priority, cache delay | `timing3.sh`, judged by `noninf.py` |
| Cache configuration | `cacheconf.sh` |
| Open time independent of file length | `fragstep.sh open`, judged by `fragjudge.py` |
| Full length never delays a step away | `fragstep.sh away`, judged by `fragjudge.py` |
| Seek by the play slider within the full length | `seekcheck.sh` |
