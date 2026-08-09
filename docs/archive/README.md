# Archive

Historical operator and planning artifacts that are no longer active work surfaces.

| Path | What |
|---|---|
| [operations/operator-report-2026-06.md](operations/operator-report-2026-06.md) | June 2026 operator-center snapshot (reconstructed; closed 2026-08) |
| [operations/operator-report-reconciliation-2026-08.md](operations/operator-report-reconciliation-2026-08.md) | Dispositions against `main` at `8696818`; closes [#18](https://github.com/lidless-labs/soc-stack/issues/18) |

Regenerate a fresh local operator report (gitignored under `.brigade/center/reports/`):

```bash
BRIGADE_EXTRAS=1 brigade center report build --target .
```
