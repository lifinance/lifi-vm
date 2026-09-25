# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue or pull request for a security vulnerability.**

Report it privately to **security@li.fi**. Include:

- the affected contract, function, and commit or deployed address;
- a description of the vulnerability and its impact;
- steps to reproduce, ideally a Foundry test that demonstrates the issue;
- any suggested fix.

## Scope

In scope:

- the contracts in `src/` at the latest commit on `main`;
- the deployed contracts listed in [`DEPLOYMENTS.md`](./DEPLOYMENTS.md).

Out of scope:

- test, script, and fuzzing code under `test/` and `script/`;
- third-party dependencies under `lib/` (report those to their maintainers);
- issues in the LI.FI API or other LI.FI products (report those through the same address, but they are not covered by this repository).

## Audits

Published audit reports are in [`audits/`](./audits).
