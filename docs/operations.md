# Operations rules

## Checkpoints

- A checkpoint lives in the artifacts of the workflow run that produced it.
- **Never delete a run that holds `cp-*` artifacts** until a newer run has
  successfully uploaded its own checkpoint (`Upload checkpoint part 0` completed
  and the run produced an APK or a newer stage checkpoint).
- `cleanup.yml` skips runs with checkpoints on purpose. Artifacts expire after
  14 days, which is the only automatic deletion allowed.
- Deletion is only for failed runs that produced no checkpoint, i.e. failures
  in prepare or before the first packing.

## Stages

- `out/` is the only checkpointed content. The source tree is re-fetched each
  stage, then source mtimes are aged so ninja reuses the restored objects.
- The checkpoint records `.ckpt-version` and `.ckpt-patches`. If either does
  not match the current build, the restored objects are discarded on purpose.
