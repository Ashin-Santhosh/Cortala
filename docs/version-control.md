# Version control

Local Git tracking starts with the current Mac source baseline on 23 October 2026, on branch main. Earlier edits were not committed and cannot be reconstructed as Git history. Historical progress notes and prior application bundles are separate evidence.

Source, tests, scripts, public benchmark fixtures, icon assets and publisher notices are tracked. Build/cache outputs, downloaded model weights, recordings, saved libraries/vaults, environment files and device-local agent/credential directories are ignored. The initial baseline scan found no audio/model files, oversized files or credential-pattern matches among eligible files; this is a limited check, not a guarantee against every possible secret.

No remote is configured and nothing has been uploaded. Future implementation changes should be committed as coherent, tested steps. A branding rename should be its own commit so it can be reviewed independently from the baseline.
