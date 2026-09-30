# Playlist stepping tests

These scripts drive a built IINA through its menus, keyboard and scroll events and read the result
back from mpv over its IPC socket and from IINA's log. They run on the test VM only: they launch
and script the app.

## Setup on the VM

- This directory is copied to `/Users/admin/Projects/iina-test`.
- The build under test is copied to `/Users/admin/Projects/Deployment/IINA/IINA.app`.
- Test media is in `/Users/admin/Projects/TestMedia-iina`: eight short clips in `review`
  (`clip01.mp4` to `clip08.mp4`) and three long files in `long` (`long01.mp4` to `long03.mp4`).
  `mkmany.py` builds the 10000-file folder `many` from the clips.
- IINA is configured with an mpv IPC socket at `/tmp/iina-mpv.sock` and logging enabled.
- `gesture.swift`, `scroll.swift` and `tcc.swift` are compiled with `swiftc` into `gesture`,
  `scroll` and `tcc`. `gesture` posts scroll events and needs the Accessibility permission.

## Cases

| Requirement | Script |
| --- | --- |
| Step resumes, step at the last entry | `step2.sh` (T1, T3) |
| Pause given with a step holds | `step2.sh` (T2), `step3.sh <delay>` |
| Folder playlist order | `assembly.sh <opened-file>` (precedence) |
| Folder playlist completeness | `assembly.sh <opened-file>`, `assembly_restart.py` |
| Scroll boundary and play state | `scroll.sh`, `scroll2.sh` |
| Thumbnail cancellation | `thumbcancel.sh` |
| Thumbnail priority, cache delay | `timing3.sh`, judged by `mwu.py` and `phases.py` |
| Cache configuration | `cacheconf.sh` |
