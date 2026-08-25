# Tvoice source baseline

This file records the source revisions preserved during the move to
`D:\разработки\Tvoice`.

| Platform | Preserved version | Source revision |
| --- | --- | --- |
| Android | 0.17.6 build 28 | `c07d43b` (`flutter/`) |
| iOS | Latest native SIP/media client | includes `3e1a159` and later unified-client changes |
| Windows | 0.17.8 build 30 | working tree based on `e29a10a` plus the exact desktop-design changes |

The primary working repository is `D:\разработки\Tvoice`. Because Flutter's
Windows analysis server does not reliably handle Cyrillic paths, builds and
tests should use the junction `D:\Tvoice-dev\Tvoice`, which points to the same
files without creating a duplicate. Immutable
platform snapshots are stored under its `releases/source-snapshots` directory.
Generated build directories, dependency caches, IDE state, and obsolete APK/ZIP
archives are intentionally excluded from the source snapshots.
