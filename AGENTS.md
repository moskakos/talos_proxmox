# Repository Guidelines

## Project structure

This repository is an Ansible role for provisioning Talos Kubernetes clusters
on Proxmox. Role defaults are in `defaults/`, orchestration tasks in `tasks/`,
and generated configuration templates in `templates/`. Keep behavior,
documentation, and tests consistent when changing the role.

## Validation

- Run `ansible-lint --offline` after Ansible role changes.
- Run `bash tests/setup_proxmox_api_test.sh` after changing
  `setup_proxmox_api.sh`; the tests mock Proxmox commands and do not modify a
  live cluster.
- Use syntax checks or focused tests for the affected behavior. Do not treat
  offline tests as a substitute for live Proxmox or Kubernetes integration
  testing.

## Commits

- Prefer atomic commits that each represent one coherent change. If splitting
  a change would make the commits incomplete or confusing, use one commit for
  the coherent whole.
- Use Conventional Commit messages, such as `fix: ...`, `feat: ...`, or
  `docs: ...`.
