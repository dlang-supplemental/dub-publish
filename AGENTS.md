# Agent notes — dub-publish

Project facts for agents. Workstation/env facts live only in `$CODE_ROOT/MEMORIES.md`. Do not recreate a per-repo `MEMORIES.md`.

- Official `dub` has no publish/submit command; registration is `POST /register_package` on code.dlang.org after session login
- Login form fields: `name`, `password` (userman); package register field: `url`, optional `ignore_fork`
- Public update webhook: `POST /api/packages/:name/update?secret=...` (no login)
- GitHub hook endpoint only honors `create` (new tags). Use `hooks install` + workflow `dub-registry-refresh.yml` (generic POST on create/delete). Repo secret: `DUB_PACKAGE_SECRET`
- GitHub: `dlang-supplemental/dub-publish`; reusable CI workflow `.github/workflows/register-package.yml`
- `/api/packages/:name/latest` returns a JSON string (quoted); unwrap before display
