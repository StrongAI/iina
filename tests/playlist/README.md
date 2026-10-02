# Playlist stepping tests

These scripts drive a built IINA through its menus, keyboard and scroll events and read the result
back from mpv over its IPC socket and from IINA's log. They run on the test VM only: they launch
and script the app.

## Setup on the VM

- This directory is copied to `/Users/admin/Projects/iina-test`.
- The build under test is copied to `/Users/admin/Projects/Deployment/IINA/IINA.app`.
- Test media is in `/Users/admin/Projects/TestMedia-iina`: eight short clips in `review`
  (`clip01.mp4` to `clip08.mp4`) and three long files in `long` (`long01.mp4` to `long03.mp4`).
  `mkmany.py` builds the 10000-file folder `many` from the clips. `frag` holds three fragmented MP4s
  that end in an `mfra` index (`frag-01m.mp4`, `frag-34m.mp4`, `frag-62m.mp4`), from which
  `fragstep_media.sh` builds the folders `fragstep.sh` opens.
- IINA is configured with an mpv IPC socket at `/tmp/iina-mpv.sock` and logging enabled.
- `gesture.swift`, `scroll.swift`, `tcc.swift` and `axctl.swift` are compiled with `swiftc` into
  `gesture`, `scroll`, `tcc` and `axctl`. `gesture` and `axctl` post events and need the
  Accessibility permission.

## Cases

| Requirement | Script |
| --- | --- |
| Step resumes, step at the last entry | `step2.sh` (T1, T3) |
| Pause given with a step holds | `step2.sh` (T2), `step3.sh <delay>` |
| Folder playlist order | `assembly.sh <opened-file>` (precedence) |
| Folder playlist completeness | `assembly.sh <opened-file>`, `assembly_restart.py` |
| Scroll boundary and play state | `scroll.sh`, `scroll2.sh` |
| Thumbnail cancellation | `thumbcancel.sh [delay]` |
| Thumbnail priority, cache delay | `timing3.sh`, judged by `mwu.py` and `phases.py` |
| Cache configuration | `cacheconf.sh` |
| Open time independent of file length | `fragstep.sh open`, judged by `fragjudge.py` |
| Full length never delays a step away | `fragstep.sh away`, judged by `fragjudge.py` |
| Seek by the play slider within the full length | `seekcheck.sh` |
