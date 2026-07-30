# Machine / environment memories

| Fact | Uses |
|------|------|
| Official `dub` has no publish/submit command; registration is `POST /register_package` on code.dlang.org after session login | 2 |
| Login form fields: `name`, `password` (userman); package register field: `url`, optional `ignore_fork` | 1 |
| Public update webhook: `POST /api/packages/:name/update?secret=...` (no login) | 1 |
| GitHub repo: `dlang-supplemental/dub-publish`; reusable CI workflow `.github/workflows/register-package.yml` | 1 |
| `/api/packages/:name/latest` returns a JSON string (quoted); unwrap before display | 1 |
