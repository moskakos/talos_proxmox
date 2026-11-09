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

## MCP tools

The following MCP servers and tools were reported as available in the
maintainer's VS Code agent session. MCP availability is supplied by the
runtime and may differ between agents or sessions; inspect the active tool
list before relying on a server.

- **GitHub MCP Server** (`github-*`): `add_comment_to_pending_review`,
  `add_issue_comment`, `add_reply_to_pull_request_comment`, `assign_copilot_to_issue`,
  `create_branch`, `create_or_update_file`, `create_pull_request`,
  `create_pull_request_with_copilot`, `create_repository`, `delete_file`,
  `delete_repository`, `fork_repository`, `get_commit`,
  `get_copilot_job_status`, `get_file_contents`, `get_latest_release`,
  `get_release_by_tag`, `get_tag`, `get_team_members`, `get_teams`,
  `issue_read`, `issue_write`, `list_branches`, `list_commits`,
  `list_issue_fields`, `list_issue_types`, `list_issues`, `list_pull_requests`,
  `list_releases`, `list_repository_collaborators`, `list_tags`,
  `merge_pull_request`, `pull_request_read`, `pull_request_review_write`,
  `push_files`, `request_copilot_review`, `run_secret_scanning`,
  `search_code`, `search_commits`, `search_issues`, `search_pull_requests`,
  `search_repositories`, `search_users`, `sub_issue_write`,
  `update_issue_comment`, `update_pull_request`, `update_pull_request_branch`.
- **GitHub Actions MCP** (`github-actions-*`): `actions_get`, `actions_list`,
  `get_job_logs`.
- **GitHub MCP Server** (`github-mcp-server-*`): `actions_get`, `actions_list`,
  `get_commit`, `get_copilot_space`, `get_file_contents`, `get_job_logs`,
  `issue_read`, `list_branches`, `list_commits`, `list_copilot_spaces`,
  `list_issues`, `list_pull_requests`, `pull_request_read`, `search_code`,
  `search_issues`, `search_pull_requests`, `search_repositories`,
  `search_users`.
- **Pylance MCP Server** (`pylance-mcp-server-*`): `pylanceAnalyze`,
  `pylanceCheckSignatureCompatibility`, `pylanceDocuments`,
  `pylanceFileSyntaxErrors`, `pylanceImports`,
  `pylanceInstalledTopLevelModules`, `pylanceInvokeRefactoring`,
  `pylanceLSP`, `pylancePythonDebug`, `pylancePythonEnvironments`,
  `pylancePythonInstallManager`, `pylancePythonProfileExplorer`,
  `pylancePythonProfiling`, `pylanceRunCodeSnippet`,
  `pylanceSettings`, `pylanceSemanticContext`,
  `pylanceSyntaxErrors`, `pylanceTypeAuthoring`,
  `pylanceUpdatePythonEnvironment`, `pylanceWorkspaceRoots`,
  `pylanceWorkspaceUserFiles`.

## Commits

- Prefer atomic commits that each represent one coherent change. If splitting
  a change would make the commits incomplete or confusing, use one commit for
  the coherent whole.
- Use Conventional Commit messages, such as `fix: ...`, `feat: ...`, or
  `docs: ...`.
