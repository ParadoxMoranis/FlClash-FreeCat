# Upstream provenance

FlClash-FreeCat is an independent repository based on [chen08209/FlClash](https://github.com/chen08209/FlClash).
The imported baseline is release `v0.9.3`, commit `be84736605527034689c95bf27828ff27d912c5e` (2026-11-04).
The initial independent snapshot includes the optional FreeCat account, subscription and profile integration.

The upstream GPL-3.0 license, existing copyright notices and bundled dependency licenses remain in place.
`CHANGELOG.md` and `changelog.json` retain upstream release history; this fork starts its own releases at `0.9.4`.
The app name and desktop/application identifiers remain FlClash for profile compatibility.

Pinned public submodules:

| Component | Repository | Commit |
| --- | --- | --- |
| mihomo Core | `chen08209/Clash.Meta` | `024245dc72bc92f48237f865119afe0cd53ac9e6` |
| prism_ui | `chen08209/prism_ui` | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` |

Clone with `--recurse-submodules`. Their own license notices and source histories remain available in those repositories.

FreeCat protocol information comes from `FREECAT_REVERSE_ENGINEERING.md`. The integration contains no user credentials
or real subscription responses. Neither FreeCat nor the upstream FlClash maintainers endorse this fork.
