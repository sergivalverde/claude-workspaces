;;; claude-workspaces.el --- Tab-based workspace manager for Claude Code agents -*- lexical-binding: t; -*-

;;; Commentary:
;; Manages multiple Claude Code agents in tab-bar tabs.
;; Each agent gets its own tab with files on the left and Claude terminal on the right.
;; A Dashboard tab provides a live control panel for all agents.
;;
;; Extends claude-code.el and replaces claude-dashboard.el.
;;
;; Usage:
;;   M-x claude-workspaces-dashboard   - Open the dashboard tab
;;   M-x claude-workspaces-launch      - Launch a new agent in a tab
;;   M-x claude-workspaces-launch-worktree - Launch in a git worktree
;;   M-x claude-workspaces-from-issue  - Launch from a GitHub issue
;;   M-x claude-workspaces-from-pr     - Launch from a GitHub PR
;;
;; Configuration example for init.el:
;;
;;   (load (expand-file-name "claude-workspaces.el" user-emacs-directory))
;;   (claude-workspaces-mode 1)
;;   (global-set-key (kbd "C-c d") #'claude-workspaces-dashboard)
;;
;;   ;; Optional GitHub repos for issue/PR commands
;;   (setq claude-workspaces-github-repos '("owner/repo"))
;;
;;   ;; Layout: 'horizontal (default), 'vertical, or 'claude-only
;;   (setq claude-workspaces-layout 'horizontal)
;;   (setq claude-workspaces-claude-window-ratio 0.4)

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'tab-bar)

;; claude-code.el must be loaded for our integration
(require 'claude-code)

(defgroup claude-workspaces nil
  "Tab-based workspace manager for Claude Code agents."
  :group 'tools
  :prefix "claude-workspaces-")

(defcustom claude-workspaces-layout 'horizontal
  "Window layout within each agent tab.
`horizontal' places files left, Claude right.
`vertical' places files top, Claude bottom.
`claude-only' shows only the Claude terminal."
  :type '(choice (const :tag "Files left, Claude right" horizontal)
                 (const :tag "Files top, Claude bottom" vertical)
                 (const :tag "Claude terminal only" claude-only))
  :group 'claude-workspaces)

(defcustom claude-workspaces-claude-window-ratio 0.4
  "Fraction of the frame width (or height) given to the Claude terminal.
The remaining space goes to the file panel."
  :type 'float
  :group 'claude-workspaces)

(defcustom claude-workspaces-default-file-fn
  #'claude-workspaces--find-project-root-file
  "Function called with PROJECT-DIR to determine which file to open initially.
Should return an absolute file path or nil."
  :type 'function
  :group 'claude-workspaces)

(defcustom claude-workspaces-worktree-dir ".claude-worktrees"
  "Directory name (relative to repo root) for storing git worktrees."
  :type 'string
  :group 'claude-workspaces)

(defcustom claude-workspaces-status-interval 3
  "Seconds between status polls for active agent buffers."
  :type 'integer
  :group 'claude-workspaces)

(defcustom claude-workspaces-github-repos nil
  "List of GitHub repos to use for issue/PR commands.
Each element is a string like \"owner/repo\"."
  :type '(repeat string)
  :group 'claude-workspaces)

(defcustom claude-workspaces-dashboard-auto-refresh t
  "When non-nil, the dashboard auto-refreshes on the status timer."
  :type 'boolean
  :group 'claude-workspaces)

;;; Internal state

(defvar claude-workspaces--active nil
  "List of active workspace plists.
Each plist has keys:
  :name        - human-readable label
  :tab-index   - tab-bar tab index
  :claude-buffer - buffer object running Claude
  :project-dir - working directory
  :session-id  - Claude session UUID (may be nil)
  :status      - one of :running :waiting :done :error
  :branch      - git branch name
  :worktree-p  - non-nil if this is a worktree
  :worktree-path - path to worktree directory (if worktree)
  :github-ref  - issue/PR reference string
  :last-modified - float-time of last buffer change detected")

(defvar claude-workspaces--status-timer nil
  "Timer for polling agent status.")

(defvar claude-workspaces--dashboard-buffer-name "*Claude Workspaces*"
  "Name of the dashboard buffer.")

;;; Workspace CRUD

(defun claude-workspaces--find-by-name (name)
  "Find workspace plist with NAME, or nil."
  (cl-find-if (lambda (ws) (string= (plist-get ws :name) name))
              claude-workspaces--active))

(defun claude-workspaces--find-by-buffer (buffer)
  "Find workspace plist whose :claude-buffer is BUFFER, or nil."
  (cl-find-if (lambda (ws) (eq (plist-get ws :claude-buffer) buffer))
              claude-workspaces--active))

(defun claude-workspaces--find-by-tab-index (index)
  "Find workspace plist at tab INDEX, or nil."
  (cl-find-if (lambda (ws) (= (plist-get ws :tab-index) index))
              claude-workspaces--active))

(defun claude-workspaces--register (workspace)
  "Add WORKSPACE plist to the active list."
  (push workspace claude-workspaces--active))

(defun claude-workspaces--unregister (workspace)
  "Remove WORKSPACE plist from the active list."
  (setq claude-workspaces--active
        (cl-remove-if (lambda (ws) (string= (plist-get ws :name)
                                             (plist-get workspace :name)))
                      claude-workspaces--active)))

(defun claude-workspaces--unique-name (base)
  "Return BASE if no workspace has that name, otherwise append a number."
  (if (not (claude-workspaces--find-by-name base))
      base
    (let ((n 2))
      (while (claude-workspaces--find-by-name (format "%s-%d" base n))
        (cl-incf n))
      (format "%s-%d" base n))))

;;; Default file finder

(defun claude-workspaces--find-project-root-file (project-dir)
  "Return a sensible default file to open for PROJECT-DIR, or nil.
Looks for README.md, index file, or the most recently modified file."
  (let ((candidates '("README.md" "README.org" "README.rst" "README"
                       "index.ts" "index.js" "main.py" "main.go"
                       "Cargo.toml" "package.json" "pyproject.toml")))
    (cl-loop for name in candidates
             for path = (expand-file-name name project-dir)
             when (file-exists-p path) return path)))

;;; Tab and layout management

(defun claude-workspaces--ensure-dashboard-tab ()
  "Ensure the Dashboard tab exists as the first tab.
Creates it if missing. Returns the tab index."
  (let ((tabs (tab-bar-tabs)))
    ;; Look for existing dashboard tab
    (cl-loop for tab in tabs
             for i from 0
             when (string= (alist-get 'name tab) "Dashboard")
             return i
             finally do
             ;; Not found - create it at position 0
             (let ((current (tab-bar--current-tab-index)))
               (tab-bar-new-tab)
               (tab-bar-rename-tab "Dashboard")
               ;; Move it to first position if not already there
               (let ((new-idx (tab-bar--current-tab-index)))
                 (when (> new-idx 0)
                   (tab-bar-move-tab (- new-idx))))
               0))))

(defun claude-workspaces--create-tab (name)
  "Create a new tab-bar tab named NAME and select it.
Returns the new tab index."
  (tab-bar-new-tab)
  (tab-bar-rename-tab name)
  (tab-bar--current-tab-index))

(defun claude-workspaces--setup-layout (project-dir claude-buffer)
  "Set up the window layout in the current tab.
PROJECT-DIR is the agent's working directory.
CLAUDE-BUFFER is the terminal buffer running Claude."
  (delete-other-windows)
  (pcase claude-workspaces-layout
    ('claude-only
     (switch-to-buffer claude-buffer))
    ('vertical
     ;; Files on top, Claude on bottom
     (let* ((file-path (funcall claude-workspaces-default-file-fn project-dir))
            (file-buf (if file-path
                         (find-file-noselect file-path)
                       (dired-noselect project-dir))))
       (switch-to-buffer file-buf)
       (let ((claude-win (split-window-below
                          (floor (* (window-height)
                                    (- 1.0 claude-workspaces-claude-window-ratio))))))
         (set-window-buffer claude-win claude-buffer))))
    (_ ; horizontal (default) - files left, Claude right
     (let* ((file-path (funcall claude-workspaces-default-file-fn project-dir))
            (file-buf (if file-path
                         (find-file-noselect file-path)
                       (dired-noselect project-dir))))
       (switch-to-buffer file-buf)
       (let ((claude-win (split-window-right
                          (floor (* (window-width)
                                    (- 1.0 claude-workspaces-claude-window-ratio))))))
         (set-window-buffer claude-win claude-buffer))))))

;;; Git helpers

(defun claude-workspaces--current-branch (dir)
  "Return the current git branch name in DIR, or nil."
  (let ((default-directory dir))
    (condition-case nil
        (let ((result (string-trim
                       (shell-command-to-string "git rev-parse --abbrev-ref HEAD 2>/dev/null"))))
          (unless (string-empty-p result) result))
      (error nil))))

;;; Agent launch

(defun claude-workspaces--start-claude-in-dir (dir buffer-name &optional initial-prompt extra-switches)
  "Start a Claude process in DIR with BUFFER-NAME.
INITIAL-PROMPT is sent after Claude starts (if non-nil).
EXTRA-SWITCHES are additional CLI flags.
Returns the Claude buffer."
  (let ((default-directory dir))
    ;; Use claude-code's own start machinery
    ;; We suppress its display function since we handle layout ourselves
    (let ((claude-code-display-window-fn #'ignore))
      (claude-code--start nil extra-switches nil nil))
    ;; Find the buffer that was just created
    (let ((buf (cl-find-if
                (lambda (b) (and (claude-code--buffer-p b)
                                 (string-match-p (regexp-quote (abbreviate-file-name (file-truename dir)))
                                                 (buffer-name b))))
                (buffer-list))))
      (when (and buf initial-prompt)
        (run-at-time 1.0 nil
                     (lambda ()
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (claude-code--term-send-string claude-code-terminal-backend initial-prompt)
                           (sit-for 0.1)
                           (claude-code--term-send-string claude-code-terminal-backend "\r"))))))
      buf)))

;;;###autoload
(defun claude-workspaces-launch (&optional dir name initial-prompt)
  "Launch a new Claude agent in its own tab.
DIR is the project directory (prompted if nil).
NAME is the workspace name (prompted if nil).
INITIAL-PROMPT is sent to Claude after startup (optional)."
  (interactive)
  (let* ((dir (or dir (read-directory-name "Project directory: ")))
         (dir (file-truename (expand-file-name dir)))
         (default-name (file-name-nondirectory (directory-file-name dir)))
         (name (or name (read-string (format "Agent name (default: %s): " default-name)
                                     nil nil default-name)))
         (name (claude-workspaces--unique-name name)))
    ;; Ensure dashboard tab exists
    (claude-workspaces--ensure-dashboard-tab)
    ;; Create agent tab
    (let ((tab-idx (claude-workspaces--create-tab name)))
      ;; Start Claude
      (let ((claude-buf (claude-workspaces--start-claude-in-dir dir name initial-prompt)))
        (if claude-buf
            (progn
              ;; Set up layout
              (claude-workspaces--setup-layout dir claude-buf)
              ;; Register workspace
              (let ((ws (list :name name
                              :tab-index tab-idx
                              :claude-buffer claude-buf
                              :project-dir dir
                              :session-id nil
                              :status :running
                              :branch (claude-workspaces--current-branch dir)
                              :worktree-p nil
                              :worktree-path nil
                              :github-ref nil
                              :last-modified (float-time))))
                (claude-workspaces--register ws)
                ;; Start status timer if not already running
                (claude-workspaces--ensure-status-timer)
                (message "Agent '%s' launched in %s" name dir)
                ws))
          ;; Failed to start
          (tab-bar-close-tab)
          (message "Failed to start Claude in %s" dir)
          nil)))))

;;; Status tracking

(defun claude-workspaces--detect-status (workspace)
  "Detect the current status of WORKSPACE and return a status keyword."
  (let* ((buf (plist-get workspace :claude-buffer))
         (proc (and (buffer-live-p buf) (get-buffer-process buf))))
    (cond
     ((not proc) :done)
     ((not (process-live-p proc))
      (if (zerop (process-exit-status proc)) :done :error))
     (t
      ;; Check buffer modification time
      (let* ((last (plist-get workspace :last-modified))
             (tick (buffer-chars-modified-tick buf))
             (stored-tick (or (plist-get workspace :mod-tick) 0)))
        (if (/= tick stored-tick)
            (progn
              (plist-put workspace :mod-tick tick)
              (plist-put workspace :last-modified (float-time))
              :running)
          ;; No modification for a while
          (if (> (- (float-time) (or last 0)) 5.0)
              :waiting
            :running)))))))

(defun claude-workspaces--status-indicator (status)
  "Return a display string for STATUS keyword."
  (pcase status
    (:running (propertize "▶" 'face 'success))
    (:waiting (propertize "⏸" 'face 'warning))
    (:done    (propertize "✓" 'face 'shadow))
    (:error   (propertize "✗" 'face 'error))
    (_ "?")))

(defun claude-workspaces--update-all-statuses ()
  "Poll all active workspaces and update their status."
  (dolist (ws claude-workspaces--active)
    (let ((new-status (claude-workspaces--detect-status ws)))
      (plist-put ws :status new-status)))
  ;; Update tab names to reflect status
  (claude-workspaces--update-tab-names)
  ;; Refresh dashboard if visible
  (when claude-workspaces-dashboard-auto-refresh
    (let ((dash-buf (get-buffer claude-workspaces--dashboard-buffer-name)))
      (when (and dash-buf (get-buffer-window dash-buf t))
        (with-current-buffer dash-buf
          (when (derived-mode-p 'claude-workspaces-dashboard-mode)
            (revert-buffer)))))))

(defun claude-workspaces--update-tab-names ()
  "Update tab-bar tab names to include status indicators."
  (dolist (ws claude-workspaces--active)
    (let* ((name (plist-get ws :name))
           (status (plist-get ws :status))
           (indicator (claude-workspaces--status-indicator status))
           (tab-name (format "%s %s" indicator name))
           (tab-idx (plist-get ws :tab-index)))
      ;; Verify tab still exists at this index
      (when (< tab-idx (length (tab-bar-tabs)))
        (tab-bar-rename-tab tab-name (1+ tab-idx))))))

(defun claude-workspaces--ensure-status-timer ()
  "Start the status polling timer if not already running."
  (unless claude-workspaces--status-timer
    (setq claude-workspaces--status-timer
          (run-with-timer claude-workspaces-status-interval
                          claude-workspaces-status-interval
                          #'claude-workspaces--update-all-statuses))))

(defun claude-workspaces--stop-status-timer ()
  "Stop the status polling timer."
  (when claude-workspaces--status-timer
    (cancel-timer claude-workspaces--status-timer)
    (setq claude-workspaces--status-timer nil)))

;;; Agent management

;;;###autoload
(defun claude-workspaces-kill (&optional name)
  "Kill the agent NAME and close its tab.
Prompts for selection if NAME is nil."
  (interactive)
  (let* ((ws (or (and name (claude-workspaces--find-by-name name))
                 (claude-workspaces--prompt-for-workspace "Kill agent: "))))
    (when ws
      (when (yes-or-no-p (format "Kill agent '%s'? " (plist-get ws :name)))
        (let ((buf (plist-get ws :claude-buffer))
              (tab-idx (plist-get ws :tab-index)))
          ;; Kill the Claude buffer
          (when (buffer-live-p buf)
            (claude-code--kill-buffer buf))
          ;; Close the tab
          (condition-case nil
              (tab-bar-close-tab (1+ tab-idx))
            (error nil))
          ;; Unregister
          (claude-workspaces--unregister ws)
          ;; Recalculate tab indices for remaining workspaces
          (claude-workspaces--recalculate-tab-indices)
          (message "Agent '%s' killed" (plist-get ws :name)))))))

;;;###autoload
(defun claude-workspaces-switch (&optional name)
  "Switch to the tab of agent NAME.
Prompts for selection if NAME is nil."
  (interactive)
  (let* ((ws (or (and name (claude-workspaces--find-by-name name))
                 (claude-workspaces--prompt-for-workspace "Switch to agent: "))))
    (when ws
      (tab-bar-select-tab (1+ (plist-get ws :tab-index))))))

(defun claude-workspaces--prompt-for-workspace (prompt)
  "Prompt user to select a workspace with PROMPT.
Returns the workspace plist or nil."
  (when claude-workspaces--active
    (let* ((names (mapcar (lambda (ws)
                            (format "%s %s [%s]"
                                    (claude-workspaces--status-indicator (plist-get ws :status))
                                    (plist-get ws :name)
                                    (file-name-nondirectory
                                     (directory-file-name (plist-get ws :project-dir)))))
                          claude-workspaces--active))
           (selection (completing-read prompt names nil t))
           (idx (cl-position selection names :test #'string=)))
      (when idx
        (nth idx claude-workspaces--active)))))

(defun claude-workspaces--recalculate-tab-indices ()
  "Recalculate :tab-index for all workspaces based on current tab order."
  (let ((tabs (tab-bar-tabs)))
    (dolist (ws claude-workspaces--active)
      (let ((name (plist-get ws :name)))
        (cl-loop for tab in tabs
                 for i from 0
                 when (string-match-p (regexp-quote name) (or (alist-get 'name tab) ""))
                 do (plist-put ws :tab-index i))))))

;;; Git worktree management

(defun claude-workspaces--repo-root (dir)
  "Return the git repository root for DIR, or nil."
  (let ((default-directory dir))
    (condition-case nil
        (let ((result (string-trim
                       (shell-command-to-string "git rev-parse --show-toplevel 2>/dev/null"))))
          (unless (string-empty-p result) result))
      (error nil))))

(defun claude-workspaces--create-worktree (repo-root name &optional base-branch)
  "Create a git worktree in REPO-ROOT for workspace NAME.
BASE-BRANCH is the branch to base off (default: current HEAD).
Returns the worktree path or nil on failure."
  (let* ((wt-dir (expand-file-name claude-workspaces-worktree-dir repo-root))
         (wt-path (expand-file-name name wt-dir))
         (branch-name (format "claude/%s" name))
         (default-directory repo-root))
    ;; Ensure worktree directory exists
    (make-directory wt-dir t)
    (let ((result (shell-command-to-string
                   (if base-branch
                       (format "git worktree add %s -b %s %s 2>&1"
                               (shell-quote-argument wt-path)
                               (shell-quote-argument branch-name)
                               (shell-quote-argument base-branch))
                     (format "git worktree add %s -b %s 2>&1"
                             (shell-quote-argument wt-path)
                             (shell-quote-argument branch-name))))))
      (if (file-directory-p wt-path)
          wt-path
        (message "Failed to create worktree: %s" result)
        nil))))

(defun claude-workspaces--remove-worktree (worktree-path)
  "Remove the git worktree at WORKTREE-PATH."
  (let ((default-directory (file-name-directory (directory-file-name worktree-path))))
    (shell-command-to-string
     (format "git worktree remove %s --force 2>&1"
             (shell-quote-argument worktree-path)))))

;;;###autoload
(defun claude-workspaces-launch-worktree (&optional dir name initial-prompt)
  "Launch a new Claude agent in a git worktree.
DIR is the repository directory (prompted if nil).
NAME is the workspace name (prompted if nil).
INITIAL-PROMPT is sent to Claude after startup."
  (interactive)
  (let* ((dir (or dir (read-directory-name "Repository directory: ")))
         (repo-root (claude-workspaces--repo-root dir)))
    (unless repo-root
      (user-error "Not a git repository: %s" dir))
    (let* ((default-name (file-name-nondirectory (directory-file-name repo-root)))
           (name (or name (read-string (format "Agent name (default: %s): " default-name)
                                       nil nil default-name)))
           (name (claude-workspaces--unique-name name))
           (wt-path (claude-workspaces--create-worktree repo-root name)))
      (if wt-path
          (let ((ws (claude-workspaces-launch wt-path name initial-prompt)))
            (when ws
              (plist-put ws :worktree-p t)
              (plist-put ws :worktree-path wt-path)
              (plist-put ws :branch (format "claude/%s" name))
              ws))
        (user-error "Failed to create worktree for '%s'" name)))))

;;; GitHub integration

(defun claude-workspaces--gh-available-p ()
  "Return non-nil if the gh CLI is available."
  (executable-find "gh"))

(defun claude-workspaces--gh-repo (&optional dir)
  "Detect the GitHub repo (owner/name) for DIR using gh."
  (let ((default-directory (or dir default-directory)))
    (condition-case nil
        (let ((result (string-trim
                       (shell-command-to-string
                        "gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null"))))
          (unless (string-empty-p result) result))
      (error nil))))

(defun claude-workspaces--gh-list-issues (repo)
  "List open issues for REPO. Returns a list of alists with number, title, body."
  (let* ((json-str (shell-command-to-string
                    (format "gh issue list --repo %s --state open --json number,title,body,labels --limit 30 2>/dev/null"
                            (shell-quote-argument repo))))
         (json-object-type 'alist)
         (json-array-type 'list))
    (condition-case nil
        (json-read-from-string json-str)
      (error nil))))

(defun claude-workspaces--gh-list-prs (repo)
  "List open PRs for REPO. Returns a list of alists."
  (let* ((json-str (shell-command-to-string
                    (format "gh pr list --repo %s --state open --json number,title,headRefName,body --limit 30 2>/dev/null"
                            (shell-quote-argument repo))))
         (json-object-type 'alist)
         (json-array-type 'list))
    (condition-case nil
        (json-read-from-string json-str)
      (error nil))))

(defun claude-workspaces--select-repo ()
  "Prompt user to select a GitHub repo.
Tries to detect from current directory first, then falls back to configured list."
  (or (claude-workspaces--gh-repo)
      (if claude-workspaces-github-repos
          (completing-read "GitHub repo: " claude-workspaces-github-repos nil t)
        (read-string "GitHub repo (owner/repo): "))))

;;;###autoload
(defun claude-workspaces-from-issue ()
  "Launch a Claude agent to work on a GitHub issue.
Creates a worktree and sends the issue context as the initial prompt."
  (interactive)
  (unless (claude-workspaces--gh-available-p)
    (user-error "gh CLI not found. Install it from https://cli.github.com"))
  (let* ((repo (claude-workspaces--select-repo))
         (issues (claude-workspaces--gh-list-issues repo)))
    (unless issues
      (user-error "No open issues found for %s" repo))
    (let* ((choices (mapcar (lambda (issue)
                              (cons (format "#%d %s"
                                            (alist-get 'number issue)
                                            (alist-get 'title issue))
                                    issue))
                            issues))
           (selection (completing-read "Select issue: " (mapcar #'car choices) nil t))
           (issue (cdr (assoc selection choices)))
           (number (alist-get 'number issue))
           (title (alist-get 'title issue))
           (body (or (alist-get 'body issue) ""))
           (name (format "issue-%d" number))
           (prompt (format "Work on issue #%d: %s\n\n%s" number title body))
           (dir (or (claude-workspaces--repo-root default-directory)
                    (read-directory-name "Repository directory: "))))
      (let ((ws (claude-workspaces-launch-worktree dir name prompt)))
        (when ws
          (plist-put ws :github-ref (format "#%d" number)))))))

;;;###autoload
(defun claude-workspaces-from-pr ()
  "Launch a Claude agent to review a GitHub PR.
Checks out the PR branch and sends the PR context as the initial prompt."
  (interactive)
  (unless (claude-workspaces--gh-available-p)
    (user-error "gh CLI not found. Install it from https://cli.github.com"))
  (let* ((repo (claude-workspaces--select-repo))
         (prs (claude-workspaces--gh-list-prs repo)))
    (unless prs
      (user-error "No open PRs found for %s" repo))
    (let* ((choices (mapcar (lambda (pr)
                              (cons (format "#%d %s [%s]"
                                            (alist-get 'number pr)
                                            (alist-get 'title pr)
                                            (alist-get 'headRefName pr))
                                    pr))
                            prs))
           (selection (completing-read "Select PR: " (mapcar #'car choices) nil t))
           (pr (cdr (assoc selection choices)))
           (number (alist-get 'number pr))
           (title (alist-get 'title pr))
           (head-ref (alist-get 'headRefName pr))
           (name (format "pr-%d" number))
           (prompt (format "Review PR #%d: %s\n\nBranch: %s\n\nPlease review this PR for code quality, correctness, and potential issues."
                           number title head-ref))
           (dir (or (claude-workspaces--repo-root default-directory)
                    (read-directory-name "Repository directory: "))))
      (let* ((repo-root (claude-workspaces--repo-root dir))
             (default-directory repo-root))
        (shell-command-to-string
         (format "gh pr checkout %d --repo %s 2>&1" number (shell-quote-argument repo)))
        (let ((ws (claude-workspaces-launch repo-root name prompt)))
          (when ws
            (plist-put ws :github-ref (format "PR #%d" number))
            (plist-put ws :branch head-ref)))))))

;;;###autoload
(defun claude-workspaces-create-pr ()
  "Create a GitHub PR from the current workspace's worktree branch.
Only works for workspaces created with `claude-workspaces-launch-worktree'."
  (interactive)
  (let ((ws (or (claude-workspaces--find-by-tab-index (tab-bar--current-tab-index))
                (claude-workspaces--prompt-for-workspace "Create PR from agent: "))))
    (unless ws
      (user-error "No workspace selected"))
    (unless (plist-get ws :worktree-p)
      (user-error "Workspace '%s' is not a worktree - can't create PR" (plist-get ws :name)))
    (let* ((wt-path (plist-get ws :worktree-path))
           (branch (plist-get ws :branch))
           (name (plist-get ws :name))
           (default-directory wt-path))
      (message "Pushing branch %s..." branch)
      (shell-command-to-string
       (format "git push -u origin %s 2>&1" (shell-quote-argument branch)))
      (let* ((title (read-string "PR title: " name))
             (body (read-string "PR body: " ""))
             (result (shell-command-to-string
                      (format "gh pr create --title %s --body %s --head %s 2>&1"
                              (shell-quote-argument title)
                              (shell-quote-argument body)
                              (shell-quote-argument branch)))))
        (message "PR created: %s" (string-trim result))))))

;;; Dashboard

(defcustom claude-workspaces-projects-dir
  (expand-file-name "projects" (expand-file-name ".claude" (getenv "HOME")))
  "Directory containing Claude Code project sessions (for historical data)."
  :type 'directory
  :group 'claude-workspaces)

(defun claude-workspaces--parse-iso-date (str)
  "Parse ISO date STR to internal time, or nil."
  (when (and str (not (string-empty-p str)))
    (condition-case nil
        (let ((cleaned (replace-regexp-in-string "Z$" "+00:00" str)))
          (date-to-time cleaned))
      (error nil))))

(defun claude-workspaces--relative-time-from-float (time)
  "Format float TIME as relative time from now."
  (let* ((diff (- (float-time) time))
         (minutes (/ diff 60))
         (hours (/ diff 3600))
         (days (/ diff 86400)))
    (cond
     ((< minutes 1) "just now")
     ((< minutes 60) (format "%dm ago" (round minutes)))
     ((< hours 24) (format "%dh ago" (round hours)))
     (t (format "%dd ago" (round days))))))

(defun claude-workspaces--relative-time (str)
  "Format ISO date STR as relative time."
  (let ((time (claude-workspaces--parse-iso-date str)))
    (if time
        (let* ((diff (float-time (time-subtract (current-time) time)))
               (minutes (/ diff 60))
               (hours (/ diff 3600))
               (days (/ diff 86400)))
          (cond
           ((< minutes 1) "just now")
           ((< minutes 60) (format "%dm ago" (round minutes)))
           ((< hours 24) (format "%dh ago" (round hours)))
           (t (format "%dd ago" (round days)))))
      "")))

(defun claude-workspaces--load-historical-sessions ()
  "Load historical sessions from Claude Code projects directory.
Returns a list of alists."
  (let ((sessions nil))
    (when (file-directory-p claude-workspaces-projects-dir)
      (dolist (project-dir (directory-files claude-workspaces-projects-dir t "^[^.]"))
        (when (file-directory-p project-dir)
          (let ((index-file (expand-file-name "sessions-index.json" project-dir))
                (project-name (file-name-nondirectory project-dir)))
            (when (file-exists-p index-file)
              (condition-case nil
                  (let* ((json-object-type 'alist)
                         (json-array-type 'list)
                         (data (json-read-file index-file))
                         (entries (alist-get 'entries data)))
                    (dolist (entry entries)
                      (push (cons (cons 'project project-name) entry) sessions)))
                (error nil)))))))
    (nreverse sessions)))

(defun claude-workspaces--dashboard-entries ()
  "Generate tabulated-list entries for the dashboard.
Active workspaces first, then recent historical sessions."
  (let ((entries nil))
    ;; Active workspaces
    (dolist (ws claude-workspaces--active)
      (let* ((name (plist-get ws :name))
             (status (plist-get ws :status))
             (project (file-name-nondirectory
                       (directory-file-name (plist-get ws :project-dir))))
             (branch (or (plist-get ws :branch) ""))
             (github-ref (or (plist-get ws :github-ref) ""))
             (last-mod (plist-get ws :last-modified))
             (age (if last-mod
                      (claude-workspaces--relative-time-from-float last-mod)
                    "")))
        (push (list (format "active:%s" name)
                    (vector
                     (format "%s %s"
                             (claude-workspaces--status-indicator status)
                             (symbol-name status))
                     name
                     project
                     branch
                     github-ref
                     age))
              entries)))
    ;; Historical sessions (most recent first, limit to 20)
    (let* ((sessions (claude-workspaces--load-historical-sessions))
           (sorted (sort sessions
                        (lambda (a b)
                          (let ((ma (or (alist-get 'modified a) ""))
                                (mb (or (alist-get 'modified b) "")))
                            (string> ma mb)))))
           (limited (seq-take sorted 20)))
      (dolist (session limited)
        (let* ((sid (or (alist-get 'sessionId session) ""))
               (project (or (alist-get 'project session) ""))
               (branch (or (alist-get 'gitBranch session) ""))
               (modified (or (alist-get 'modified session) "")))
          (push (list (format "session:%s" sid)
                      (vector
                       (propertize "✓ done" 'face 'shadow)
                       (truncate-string-to-width
                        (or (alist-get 'firstPrompt session) "—") 20 nil nil t)
                       project
                       branch
                       ""
                       (claude-workspaces--relative-time modified)))
                entries))))
    (nreverse entries)))

(defun claude-workspaces--dashboard-action ()
  "Action for RET in the dashboard.
For active agents: switch to their tab.
For historical sessions: offer to resume."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (cond
       ((string-prefix-p "active:" id)
        (let* ((name (substring id 7))
               (ws (claude-workspaces--find-by-name name)))
          (when ws
            (tab-bar-select-tab (1+ (plist-get ws :tab-index))))))
       ((string-prefix-p "session:" id)
        (let ((sid (substring id 8)))
          (message "Resume session %s? Use claude-workspaces-resume for full functionality." sid)))))))

(defvar claude-workspaces-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-workspaces--dashboard-action)
    (define-key map (kbd "n")   #'claude-workspaces-launch)
    (define-key map (kbd "w")   #'claude-workspaces-launch-worktree)
    (define-key map (kbd "i")   #'claude-workspaces-from-issue)
    (define-key map (kbd "p")   #'claude-workspaces-from-pr)
    (define-key map (kbd "k")   #'claude-workspaces-kill)
    (define-key map (kbd "P")   #'claude-workspaces-create-pr)
    (define-key map (kbd "g")   #'claude-workspaces-dashboard-refresh)
    (define-key map (kbd "s")   #'claude-workspaces-switch)
    (define-key map (kbd "?")   #'claude-workspaces-dashboard-help)
    map)
  "Keymap for `claude-workspaces-dashboard-mode'.")

(define-derived-mode claude-workspaces-dashboard-mode tabulated-list-mode "Claude Workspaces"
  "Major mode for the Claude Workspaces dashboard.

\\{claude-workspaces-dashboard-mode-map}"
  (setq tabulated-list-format
        [("Status" 12 t)
         ("Name" 20 t)
         ("Project" 15 t)
         ("Branch" 25 t)
         ("Ref" 8 t)
         ("Last Active" 12 t)])
  (setq tabulated-list-sort-key nil)
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header)
  (setq tabulated-list-entries #'claude-workspaces--dashboard-entries)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (tabulated-list-print t))))

(defun claude-workspaces-dashboard-refresh ()
  "Refresh the dashboard."
  (interactive)
  (when (derived-mode-p 'claude-workspaces-dashboard-mode)
    (revert-buffer)
    (message "Dashboard refreshed")))

(defun claude-workspaces-dashboard-help ()
  "Show dashboard key bindings."
  (interactive)
  (message "n:new  w:worktree  i:issue  p:PR  k:kill  P:create-PR  s:switch  g:refresh  RET:go"))

;;;###autoload
(defun claude-workspaces-dashboard ()
  "Open or switch to the Claude Workspaces dashboard tab."
  (interactive)
  (tab-bar-mode 1)
  (claude-workspaces--ensure-dashboard-tab)
  (tab-bar-select-tab 1)
  (let ((buf (get-buffer-create claude-workspaces--dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-workspaces-dashboard-mode)
        (claude-workspaces-dashboard-mode))
      (revert-buffer))
    (switch-to-buffer buf)))

;;; Global minor mode

;;;###autoload
(define-minor-mode claude-workspaces-mode
  "Global minor mode for Claude Workspaces.
Enables tab-bar-mode and sets up the dashboard tab."
  :global t
  :lighter " CW"
  :group 'claude-workspaces
  (if claude-workspaces-mode
      (progn
        (tab-bar-mode 1)
        (claude-workspaces--ensure-status-timer)
        (message "Claude Workspaces mode enabled"))
    (claude-workspaces--stop-status-timer)
    (message "Claude Workspaces mode disabled")))

(provide 'claude-workspaces)
;;; claude-workspaces.el ends here
