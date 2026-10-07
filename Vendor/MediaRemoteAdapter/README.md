# MediaRemote Adapter

Copied from https://github.com/ungive/mediaremote-adapter
(commit 29718252613a5b0e210bdc64de0bd944ab379706, BSD 3-Clause, see LICENSE),
without the test client (only its header, which `test.m` imports).

Since macOS 15.4 only Apple's own programs may read what's playing through the
private MediaRemote framework. `/usr/bin/perl` is one of them: Liland runs
`bin/mediaremote-adapter.pl` with it, and the script loads this framework,
which streams the system's Now Playing as JSON lines.

To update, replace `bin/`, `include/` and `src/` with the new upstream files.
