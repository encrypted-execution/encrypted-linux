# scripts/upstream/

Vendored upstream artifacts that the encrypted-linux build consumes
verbatim. We commit them rather than fetching at build time so that:

1. Builds are hermetic (no network at build time).
2. The exact upstream revision is auditable from git history.
3. Changing the vendored copy is a reviewable diff, not a silent
   `curl` substitution.

## Inventory

| File | Upstream source | Upstream version | Consumer |
|---|---|---|---|
| `syscall_64.tbl` | [`arch/x86/entry/syscalls/syscall_64.tbl`](https://raw.githubusercontent.com/torvalds/linux/v6.6/arch/x86/entry/syscalls/syscall_64.tbl) | Linux v6.6 (release tag `v6.6`) | `scripts/gen-unistd-seeded.py` (Track B1) |

## Refreshing a vendored file

```sh
# Example for syscall_64.tbl
curl -fsSL \
  https://raw.githubusercontent.com/torvalds/linux/v6.6/arch/x86/entry/syscalls/syscall_64.tbl \
  -o scripts/upstream/syscall_64.tbl
git add scripts/upstream/syscall_64.tbl
git commit -m "Refresh vendored syscall_64.tbl from upstream <tag>"
```

When you refresh, also:

- Bump the "Upstream version" column above.
- Regenerate any downstream artifacts that consume the file
  (e.g. `python3 scripts/gen-unistd-seeded.py`) and verify nothing
  breaks. New rows in `syscall_64.tbl` will get new seeded slots; old
  rows that disappeared simply leave their slots unmapped.

## Why not a git submodule?

Submodules pin a whole tree; we only need a couple of plain text
files. Vendoring individual files keeps the dependency surface
inspectable from the encrypted-linux repo alone.
