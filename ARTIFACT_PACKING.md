# SC2026 — packing the A2 Zenodo artifact

Recipe for building `A2-cloudsc-sc2026.tar.gz`, published on Zenodo
(record 19708601). The tarball is a source snapshot with VCS metadata
stripped, so a reviewer can unpack and build without git history or
access to a forge.

This file lives in the tree it describes, so the recipe travels with the
artifact.

The A1 tarballs (`dace`, `icon-dace`, `icon-vt-dace`) are packed from a
different checkout; see `velocity/ARTIFACT_PACKING.md` in the ico2 tree.

## Why `git archive` and not `tar --exclude`

Everything the artifact ships is tracked, and everything bulky is not:

| Shipped, tracked | Not shipped, untracked |
|---|---|
| `src/`, `arch/`, `cmake/`, `CMakeLists.txt`, `cloudsc-bundle`, `bundle.yml` | `source/`, `ecbundle/` — fetched by `./cloudsc-bundle create` |
| `config-files/{input,reference}.h5`, `cloudsc.bin` | `build/` — reviewers rebuild it, and it reaches ~450 GB after a full sweep |
| `*.sh`, `*.py` drivers | `venv/` — rebuilt in §0 of the HOWTOs |
| `ptx/{fp64,fp32,fp16,fp16r}/cloudsc.{ptx,sass}` | generated inputs: `input_spunup.h5`, `config-files/input_2xklev.h5` |
| `cloudsc_results.db` | `figs/`, `profile/`, `*.ncu-rep`, `build_stash/` |
| `SC2026_HOWTO.{daint,ault}.md`, `README.md` | editor/OS scratch: `.DS_Store`, `.vscode/`, `.ruff_cache/`, `__pycache__/` |

So `git archive` selects the right set by construction. It emits no
`.git/`, ignores untracked working files rather than requiring each to be
named, and writes no macOS AppleDouble (`._*`) or `LIBARCHIVE.xattr.*`
entries — so it is safe to pack from macOS, unlike `tar`.

The `ptx/` dumps are a deliberate inclusion. `.gitignore` lists `ptx/`,
but those seven files were tracked before that rule landed and remain
tracked; `git archive` ships tracked files regardless of ignore rules.
They let a reviewer read the generated PTX and SASS — including the
`fp16r` restricted-half variant, which `build_all.sh` does not build by
default — without first reproducing a build.

`cloudsc_results.db` ships so the reported numbers can be queried without
re-running anything. §6 of `SC2026_HOWTO.daint.md` documents the schema.

Because `git archive` reads committed state, commit before packing.
Working-tree edits are silently omitted, which is the correct behaviour
for a reproducible artifact but surprising if unexpected.

## Packing

```bash
cd <dwarf-p-cloudsc-checkout>

git rev-parse HEAD                      # note this; it is the artifact's provenance

git archive --format=tar \
    --prefix=A2-cloudsc-sc2026/ \
    HEAD \
  | gzip > A2-cloudsc-sc2026.tar.gz

sha256sum A2-cloudsc-sc2026.tar.gz
```

Roughly 9 MB. The tarball unpacks into a single top-level
`A2-cloudsc-sc2026/`, so extraction never scatters files into the current
directory.

To pack a specific revision rather than the current one, substitute a tag
or SHA for `HEAD`.

## Verify before upload

```bash
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c '/\.git/'                       # 0
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c '^\._\|/\._'                    # 0
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -cE '/(venv|build|source|ecbundle)/'  # 0
tar -tzf A2-cloudsc-sc2026.tar.gz | awk -F/ '{print $1}' | sort -u          # A2-cloudsc-sc2026

tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c 'config-files/input.h5'         # 1
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c 'config-files/reference.h5'     # 1
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c 'cloudsc.sass'                  # 4
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c 'cloudsc_results.db'            # 1
tar -tzf A2-cloudsc-sc2026.tar.gz | grep -c 'SC2026_HOWTO'                  # 2
```

The input and reference HDF5 files are what make the artifact
self-contained: without them a reviewer cannot run the dwarf at all, and
nothing in the build fetches them.

Two HOWTOs must travel — the daint (GH200) and ault (A100) recipes are
not interchangeable, and the ault one is the only place the A100 memory
ceiling and its NVHPC 23.3 requirement are written down.

Revision-pinning checks for the current artifact:

```bash
tar -xzOf A2-cloudsc-sc2026.tar.gz A2-cloudsc-sc2026/src/cloudsc_gpu/cloudsc_gpu_scc_k_caching_mod.F90 \
  | grep -c 'ZTP1(JK_I)\*ZESATLIQ'                                          # 1
tar -xzOf A2-cloudsc-sc2026.tar.gz A2-cloudsc-sc2026/run_all.ault.sh \
  | grep -c 'nodelist=ault25'                                               # 1
```

The first pins the ZTP1 k-cache fix: `ZTP1` is a two-element k-cache, and
the `ZEVAP_DENOM` line indexing it with the full level index `JK` instead
of `JK_I` read out of bounds. It corrupted results at every `KLEV` and
crashed outright for `KLEV != 137`. An artifact predating that fix does
not reproduce the paper.

The second confirms the ault run script travels; it is a separate file
from `run_all.sh` because the SBATCH headers differ (partition, nodelist,
no uenv) and ault cannot use the daint one.

## Uploading

Upload as a new version of the existing Zenodo record. Record the git SHA
noted above in the version description, so the archived tarball stays
traceable to a commit after the branch moves on.
