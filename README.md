# claude-workspaces.el

Manage multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents from Emacs using `tab-bar-mode`. Each agent gets its own tab with your project files on the left and the Claude terminal on the right. A Dashboard tab gives you a live control panel for everything.

## Why

Claude Code is great for coding, but once you're running 3-4 agents on different tasks, keeping track of them gets messy. You end up juggling terminal windows, losing track of which agent is doing what, and context-switching between projects manually.

This package turns Emacs into a proper multi-agent workspace. Each agent is spatially organized in its own tab, status updates show up in the tab bar, and you can launch new agents from GitHub issues with a single keypress. Git worktrees give each agent full isolation so they never step on each other.

## Requirements

- Emacs 30+ (for `tab-bar-mode`)
- [claude-code.el](https://github.com/stevemolitor/claude-code.el)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and on your PATH
- `eat` or `vterm` (terminal backend, used by claude-code.el)
- [`gh` CLI](https://cli.github.com) (optional, for GitHub issue/PR features)

## Installation

### With use-package (recommended)

```elisp
;; Install claude-code.el first
(use-package claude-code :ensure t
  :demand t
  :vc (:url "https://github.com/stevemolitor/claude-code.el" :rev :newest)
  :config
  (claude-code-mode)
  :bind-keymap ("C-c c" . claude-code-command-map))

;; Install claude-workspaces
(use-package claude-workspaces :ensure t
  :demand t
  :vc (:url "https://github.com/sergivalverde/claude-workspaces" :rev :newest)
  :config
  (claude-workspaces-mode 1)
  :bind ("C-c d" . claude-workspaces-dashboard))
```

### Manual

Clone this repo somewhere Emacs can find it:

```bash
git clone https://github.com/sergivalverde/claude-workspaces ~/.emacs.d/claude-workspaces
```

Add to your `init.el`:

```elisp
(load (expand-file-name "claude-workspaces/claude-workspaces.el" user-emacs-directory))
(claude-workspaces-mode 1)
(global-set-key (kbd "C-c d") #'claude-workspaces-dashboard)
```

## Quick Start

Press `C-c d` to open the dashboard. From there, everything is one keypress away.

## The Dashboard

The dashboard is your command center. It's always the first tab.

```
Status       Name                 Project         Branch                    Ref      Last Active
▶ :running   auth-fix             myapp           claude/issue-42           #42      2m ago
⏸ :waiting   api-tests            myapp           claude/api-tests                   just now
✓ done       old-session          myapp           main                               3d ago
```

Active agents appear at the top with live status. Historical sessions from Claude Code appear below.

### Dashboard Keys

| Key   | Action                                  |
|-------|-----------------------------------------|
| `RET` | Jump to agent's tab (or resume session) |
| `n`   | Launch new agent from a directory       |
| `w`   | Launch agent in a git worktree          |
| `i`   | Launch agent from a GitHub issue        |
| `p`   | Launch agent from a GitHub PR           |
| `k`   | Kill an agent and close its tab         |
| `P`   | Create a PR from a worktree agent       |
| `s`   | Switch to an agent by name              |
| `g`   | Refresh the dashboard                   |
| `?`   | Show key help                           |

## Launching Agents

### From a local directory (`n`)

1. Press `n` in the dashboard
2. Pick a project directory
3. Name your agent (defaults to the directory name)
4. A new tab opens: project files left, Claude right

### In a git worktree (`w`)

This is the power feature for parallel work. Each agent gets an isolated copy of the repo on its own branch.

1. Press `w` in the dashboard
2. Pick the repository directory
3. Name your agent (e.g., "auth-fix")
4. A worktree is created at `<repo>/.claude-worktrees/auth-fix/` on branch `claude/auth-fix`
5. Claude starts in the worktree - changes don't affect your main branch

You can have 4+ agents all working on the same repo simultaneously without conflicts.

### From a GitHub issue (`i`)

1. Press `i` in the dashboard
2. Select a repo (auto-detected if you're in one, or choose from configured list)
3. Select an issue from the list of open issues
4. A worktree is created and Claude starts with the issue context as its prompt

### From a GitHub PR (`p`)

1. Press `p` in the dashboard
2. Select a PR from the open PRs list
3. The PR branch is checked out
4. Claude starts with a review prompt

> **Note:** The `i` and `p` commands require the `gh` CLI to be installed and authenticated.

## Status Indicators

The tab bar shows live status for each agent, updated every 3 seconds:

| Indicator | Meaning                              |
|-----------|--------------------------------------|
| `▶`       | Running - Claude is actively working |
| `⏸`       | Waiting - Claude is idle (>5 seconds)|
| `✓`       | Done - process has exited            |
| `✗`       | Error - process exited with error    |

## Creating a PR from a Worktree (`P`)

After an agent finishes work in a worktree:

1. Press `P` in the dashboard
2. The branch is pushed to origin
3. You're prompted for a PR title and body
4. The PR is created via `gh pr create`

## Configuration

```elisp
;; Layout: 'horizontal (default), 'vertical, or 'claude-only
(setq claude-workspaces-layout 'horizontal)

;; How much space Claude gets (0.0-1.0, default 0.4 = 40%)
(setq claude-workspaces-claude-window-ratio 0.4)

;; Where worktrees are created (relative to repo root)
(setq claude-workspaces-worktree-dir ".claude-worktrees")

;; Status polling interval in seconds (default 3)
(setq claude-workspaces-status-interval 3)

;; Pre-configured GitHub repos for issue/PR commands
(setq claude-workspaces-github-repos '("owner/repo1" "owner/repo2"))

;; Auto-refresh dashboard when visible (default t)
(setq claude-workspaces-dashboard-auto-refresh t)
```

## All Commands

| Command                              | Description                        |
|--------------------------------------|------------------------------------|
| `claude-workspaces-dashboard`        | Open the dashboard (`C-c d`)       |
| `claude-workspaces-launch`           | Launch agent from directory        |
| `claude-workspaces-launch-worktree`  | Launch agent in git worktree       |
| `claude-workspaces-from-issue`       | Launch agent from GitHub issue     |
| `claude-workspaces-from-pr`          | Launch agent from GitHub PR        |
| `claude-workspaces-kill`             | Kill an agent                      |
| `claude-workspaces-switch`           | Switch to an agent's tab           |
| `claude-workspaces-create-pr`        | Create PR from worktree            |
| `claude-workspaces-dashboard-refresh`| Refresh the dashboard              |

## Typical Workflows

### Parallel feature development

1. `C-c d` to open dashboard
2. `w` three times to launch three worktree agents on different features
3. Give each agent its task
4. Switch between tabs to monitor progress
5. `P` on each to create PRs when done

### Issue triage

1. `C-c d` then `i`
2. Pick an issue, agent starts working on it
3. Repeat for more issues
4. Dashboard shows all agents and their status

### Code review

1. `C-c d` then `p`
2. Pick a PR to review
3. Claude analyzes the code in context

## License

GPL-3.0
