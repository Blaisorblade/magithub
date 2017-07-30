;;; magithub-core.el --- core functions for magithub  -*- lexical-binding: t; -*-

;; Copyright (C) 2016-2017  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'magit)
(require 'dash)
(require 's)
(require 'subr-x)
(require 'ghub)
(require 'bug-reference)

(defvar magithub-debug-mode nil)
(defun  magithub-debug-mode (&optional submode)
  (and (listp magithub-debug-mode)
       (memq submode magithub-debug-mode)))
(defun magithub-debug-message (fmt &rest args)
  "Print a debug message.
Respects `magithub-debug-mode' and `debug-on-error'."
  (when (or magithub-debug-mode debug-on-error)
    (let ((print-quoted t))
      (message "magithub: (%s) %s"
               (format-time-string "%M:%S.%3N" (current-time))
               (apply #'format fmt args)))))
(defun magithub-debug--ghub-request-wrapper (oldfun &rest args)
  (magithub-debug-message "ghub-request%S" args)
  (unless (magithub-debug-mode 'dry-api)
    (apply oldfun args)))
(advice-add #'ghub-request :around #'magithub-debug--ghub-request-wrapper)

(defcustom magithub-dir
  (expand-file-name "magithub" user-emacs-directory)
  "Data directory.
Various Magithub data (such as the cache) will be dumped into the
root of this directory.

If it does not exist, it will be created."
  :group 'magithub
  :type 'directory)

(defmacro magithub-in-data-dir (&rest forms)
  "Execute forms in `magithub-dir'.
If `magithub-dir' does not yet exist, it and its parents will be
created automatically."
  `(progn
     (unless (file-directory-p magithub-dir)
       (mkdir magithub-dir t))
     (let ((default-directory magithub-dir))
       ,@forms)))

(defun magithub-github-repository-p ()
  "Non-nil if \"origin\" points to GitHub or a whitelisted domain."
  (when-let ((origin (magit-get "remote" "origin" "url")))
    (-some? (lambda (domain) (s-contains? domain origin))
            (cons "github.com" (magit-get-all "hub" "host")))))

(defvar magithub-cache 'expire
  "Determines how the cache behaves.

If nil, the cache will not be used to read cached data.  It will
still be updated and written to disk.

If t, *only* the cache will be used.  This constitutes Magithub's
'offline' mode.

If `expire', the cache will expire with the passage of time
according to `magithub-cache-class-refresh-seconds-alist'.  This
is the default behavior.

A fourth value, `hard-refresh-offline', counts towards both
`magithub-offline-p' and `magithub-cache--always-p'.  It should
only be let-bound by `magithub-refresh'.")

(defun magithub-go-offline ()
  (interactive)
  (setq magithub-cache t)
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(defun magithub-go-online ()
  (interactive)
  (setq magithub-cache 'expire)
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(defun magithub-toggle-offline ()
  (interactive)
  (if (magithub-offline-p)
      (magithub-go-online)
    (magithub-go-offline)))

(defun magithub-offline-p ()
  (memq magithub-cache '(t hard-refresh-offline)))

(defvar magithub--api-last-available
  ;; see https://travis-ci.org/vermiculus/magithub/jobs/259006323
  ;; (eval-when-compile (date-to-time "1/1/1970"))
  '(14445 17280)
  "The last time the API was available.
Used to avoid pinging GitHub multiple times a second.")

(defcustom magithub-api-timeout 1
  "Number of seconds we'll wait for the API to respond."
  :group 'magithub
  :type 'integer)

(defcustom magithub-api-low-threshold 15
  "Low threshold for API requests.
This variable is not currently respected; see tarsius/ghub#16.

If the number of available API requests drops to or below this
threshold, you'll be asked if you'd like to go offline."
  :group 'magithub
  :type 'integer)

(defun magithub--api-available-p (&optional ignore-offline-mode)
  "Non-nil if the API is available.

Pings the API a maximum of once every ten seconds."
  (magithub-debug-message "checking if the API is available")
  (unless (and (not ignore-offline-mode) (magithub-offline-p))
    (if (and magithub--api-last-available
             (< (time-to-seconds (time-subtract (current-time) magithub--api-last-available)) 10))
        (prog1 magithub--api-last-available
          (magithub-debug-message "used cached value for api-last-available"))

      (magithub-debug-message "cache expired; retrieving new value for api-last-available")
      (let* (error-data
             go-offline-message
             status
             (response (with-timeout (magithub-api-timeout 'timeout)
                         (condition-case err (ghub-get "/meta")
                           (error (setq error-data err) 'errored-out)))))

        (magithub-debug-message
         (concat "new value retrieved for api-last-available"
                 (when (magithub-debug-mode 'forms)
                   (format ": %S" response))))

        (if (symbolp response)
            (setq go-offline-message
                  (alist-get response
                             '((timeout . "API is not responding quickly")
                               (errored-out . "API call resulted in error"))
                             "Unknown issue with API access"))
          (setq status t
                magithub--api-last-available (current-time)))

        (when error-data
          (magithub-debug-message "%S" error-data))

        (when go-offline-message
          (if (y-or-n-p (format "%s; go offline? " go-offline-message))
              (magithub-go-offline)
            (message "Consider customizing `magithub-api-timeout' if this happens often")))

        status))))

(defun magithub--completing-read (prompt collection &optional format-function predicate require-match default)
  "Using PROMPT, get a list of elements in COLLECTION.
This function continues until all candidates have been entered or
until the user enters a value of \"\".  Duplicate entries are not
allowed."
  (let* ((format-function (or format-function (lambda (o) (format "%S" o))))
         (collection (if (functionp predicate) (-filter predicate collection) collection))
         (collection (magithub--zip collection format-function nil)))
    (cdr (assoc-string
          (completing-read prompt collection nil require-match
                           (when default (funcall format-function default)))
          collection))))

(defun magithub--completing-read-multiple (prompt collection &optional format-function predicate require-match default)
  "Using PROMPT, get a list of elements in COLLECTION.
This function continues until all candidates have been entered or
until the user enters a value of \"\".  Duplicate entries are not
allowed."
  (let ((this t) (coll (copy-tree collection)) ret)
    (while (and collection this)
      (setq this (magithub--completing-read
                  prompt coll format-function
                  predicate require-match default))
      (when this
        (push this ret)
        (setq coll (delete this coll))))
    ret))

(defconst magithub-hash-regexp
  (rx bow (= 40 (| digit (any (?A . ?F) (?a . ?f)))) eow)
  "Regexp for matching commit hashes.")

(defcustom magithub-hub-executable "hub"
  "The hub executable used by Magithub."
  :group 'magithub
  :package-version '(magithub . "0.1")
  :type 'string)

(defvar magithub-hub-error nil
  "When non-nil, this is a message for when hub fails.")

(defmacro magithub-with-hub (&rest body)
  `(let ((magit-git-executable magithub-hub-executable)
         (magit-pre-call-git-hook nil)
         (magit-git-global-arguments nil))
     ,@body))

(defun magithub--hub-command (magit-function command args)
  (unless (executable-find magithub-hub-executable)
    (user-error "Hub (hub.github.com) not installed; aborting"))
  (unless (file-exists-p "~/.config/hub")
    (user-error "Hub hasn't been initialized yet; aborting"))
  (magithub-debug-message "Calling hub with args: %S %S" command args)
  (with-timeout (5 (error "Took too long!  %s%S" command args))
    (magithub-with-hub (funcall magit-function command args))))

(defun magithub--git-raw-output (&rest args)
  "Execute Git with ARGS, returning its output as string.
Adapted from `magit-git-lines'."
  (with-temp-buffer
    (apply #'magit-git-insert args)
    (buffer-string)))

(defun magithub--command (command &optional args)
  "Run COMMAND synchronously using `magithub-hub-executable'."
  (magithub--hub-command #'magit-run-git command args))

(defun magithub--command-with-editor (command &optional args)
  "Run COMMAND asynchronously using `magithub-hub-executable'.
Ensure GIT_EDITOR is set up appropriately."
  (magithub--hub-command #'magit-run-git-with-editor command args))

(defun magithub--command-output (command &optional args raw)
  "Run COMMAND synchronously using `magithub-hub-executable'.
If not RAW, return output as a list of lines."
  (magithub--hub-command (if raw #'magithub--git-raw-output #'magit-git-lines) command args))

(defun magithub--command-quick (command &optional args)
  "Quickly execute COMMAND with ARGS."
  (ignore (magithub--command-output command args)))

(defun magithub-hub-version ()
  "Return the `hub' version as a string."
  (thread-first "--version"
    magithub--command-output cadr
    split-string cddr car
    (split-string "-") car))

(defun magithub-hub-version-at-least (version-string)
  "Return t if `hub's version is at least VERSION-STRING."
  (version<= version-string (magithub-hub-version)))

(defun magithub--meta-new-issue ()
  "Open a new Magithub issue.
See /.github/ISSUE_TEMPLATE.md in this repository."
  (interactive)
  (browse-url "https://github.com/vermiculus/magithub/issues/new"))

(defun magithub--meta-help ()
  "Open Magithub help."
  (interactive)
  (browse-url "https://gitter.im/vermiculus/magithub"))

(defun magithub-enable ()
  "Enable Magithub for this repository."
  (interactive)
  (magit-set "yes" "magithub" "enabled")
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(defun magithub-disable ()
  "Disable Magithub for this repository."
  (interactive)
  (magit-set "no" "magithub" "enabled")
  (when (derived-mode-p 'magit-status-mode)
    (magit-refresh)))

(defun magithub-enabled-p ()
  "Returns non-nil when Magithub is enabled for this repository."
  (when (member (magit-get "magithub" "enabled") '("yes" nil)) t))

(defun magithub-enabled-toggle ()
  "Toggle Magithub"
  (interactive)
  (if (magithub-enabled-p)
      (magithub-disable)
    (magithub-enable)))

(defun magithub-usable-p ()
  "Non-nil if Magithub should do its thing."
  (and (magithub-enabled-p)
       (magithub-github-repository-p)
       (or (and (magithub-offline-p)
                ;; if we're offline, source-repo will get the cached value
                (magithub-source-repo))
           (and (magithub--api-available-p)
                ;; otherwise, we only want to query the API if it's available
                (magithub-source-repo)))))

(defun magithub-error (err-message tag &optional trace)
  "Report a Magithub error."
  (setq trace (or trace (with-output-to-string (backtrace))))
  (when (y-or-n-p (concat tag "  Report?  (A bug report will be placed in your clipboard.)"))
    (with-current-buffer-window
     (get-buffer-create "*magithub issue*")
     #'display-buffer-pop-up-window nil
     (when (fboundp 'markdown-mode) (markdown-mode))
     (insert
      (kill-new
       (format
        "## Automated error report

### Description

%s

### Backtrace

```
%s```
"
        (read-string "Briefly describe what you were doing: ")
        trace))))
    (magithub--meta-new-issue))
  (error err-message))

(defmacro magithub--deftoggle (name hook func s)
  "Define a section-toggle command."
  (declare (indent defun))
  `(defun ,name ()
     ,(concat "Toggle the " s " section.")
     (interactive)
     (if (memq ,func ,hook)
         (remove-hook ',hook ,func)
       (add-hook ',hook ,func t))
     (when (derived-mode-p 'magit-status-mode)
       (magit-refresh))
     (memq ,func ,hook)))

(defun magithub--zip-case (p e)
  "Get an appropriate value for element E given property/function P."
  (cond
   ((null p) e)
   ((functionp p) (funcall p e))
   ((symbolp p) (plist-get e p))
   (t nil)))

(defun magithub--zip (object-list prop1 prop2)
  "Process OBJECT-LIST into an alist defined by PROP1 and PROP2.

If a prop is a symbol, that property will be used.

If a prop is a function, it will be called with the
current element of OBJECT-LIST.

If a prop is nil, the entire element is used."
  (delq nil
        (-zip-with
         (lambda (e1 e2)
           (let ((p1 (magithub--zip-case prop1 e1))
                 (p2 (magithub--zip-case prop2 e2)))
             (unless (or (and prop1 (not p1))
                         (and prop2 (not p2)))
               (cons (if prop1 p1 e1)
                     (if prop2 p2 e2)))))
         object-list object-list)))

(defconst magithub-feature-list
  '(pull-request-merge pull-request-checkout)
  "All magit-integration features of Magithub.

`pull-request-merge'
Apply patches from pull request

`pull-request-checkout'
Checkout pull requests as new branches")

(defvar magithub-features nil
  "An alist of feature-symbols to Booleans.
When a feature symbol maps to non-nil, that feature is considered
'loaded'.  Thus, to disable all messages, prepend '(t . t) to
this list.

Example:

    ((pull-request-merge . t) (other-feature . nil))

signals that `pull-request-merge' is a loaded feature and
`other-feature' has not been loaded and will not be loaded.

To enable all features, see `magithub-feature-autoinject'.

See `magithub-feature-list' for a list and description of features.")

(defun magithub-feature-check (feature)
  "Check if a Magithub FEATURE has been configured.
See `magithub-features'."
  (if (listp magithub-features)
      (let* ((p (assq feature magithub-features)))
        (if (consp p) (cdr p)
          (cdr (assq t magithub-features))))
    magithub-features))

(defun magithub-feature-maybe-idle-notify (&rest feature-list)
  "Notify user if any of FEATURES are not yet configured."
  (unless (-all? #'magithub-feature-check feature-list)
    (let ((m "Magithub features not configured: %S")
          (s "see variable `magithub-features' to turn off this message"))
      (run-with-idle-timer
       1 nil (lambda ()
               (message (concat m "; " s) feature-list)
               (add-to-list 'feature-list '(t . t) t))))))

(defun magithub--parse-url (url)
  "Parse URL into its components.
URL may be of several different formats:

- git@github.com:vermiculus/magithub.git
- https://github.com/vermiculus/magithub"
  (and url
       (or (and (string-match
                 ;; git@github.com:vermiculus/magithub.git
                 (rx bol
                     (group (+? any)) ;sshuser -- git
                     "@"
                     (group (+? any)) ;domain  -- github.com
                     ":"
                     (group (+? (| alnum "-" "."))) ;owner.login -- vermiculus
                     "/"
                     (group (+? (| alnum "-" "."))) ;name -- magithub
                     (? ".git")
                     eol)
                 url)
                `((kind . 'ssh)
                  (ssh-user . (match-string 1 url))
                  (domain . (match-string 2 url))
                  (sparse-repo (owner (login . ,(match-string 3 url)))
                               (name . ,(match-string 4 url)))))
           (and (string-match
                 ;; https://github.com/vermiculus/magithub.git
                 ;; git://github.com/vermiculus/magithub.git
                 (rx bol
                     (or (seq "http" (? "s"))
                         "git")
                     "://"
                     (group (+? any)) ;domain -- github.com
                     "/"
                     (group (+? (| alnum "-" "."))) ;owner.login -- vermiculus
                     "/"
                     (group (+? (| alnum "-" "."))) ;name -- magithub
                     (? ".git")
                     eol)
                 url)
                `((kind . 'http)
                  (domain . (match-string 1 url))
                  (sparse-repo (owner (login . ,(match-string 2 url)))
                               (name . ,(match-string 3 url))))))))

(defun magithub--url->repo (url)
  "Tries to parse a remote url into a GitHub repository object"
  (cdr (assq 'sparse-repo (magithub--parse-url url))))

(defun magithub-source--remote ()
  "Tries to determine the correct remote to use for issue-tracking."
  (or (magit-get "magithub" "proxy") "origin"))

(defun magithub-source-repo ()
  "Returns a sparse repository object for the current context.

Uses the URL of `magithub-source-remote' to parse out repository
information.  Returns a full repository object."
  (magithub-cache :repo-demographics
    `(condition-case e
         (ghubp-get-repos-owner-repo
          ',(magithub-source--sparse-repo))
       (ghub-404
        ;; Repo may not exist; ignore 404
        nil))))

(defun magithub--satisfies-p (preds obj)
  "Non-nil when all functions in PREDS are non-nil for OBJ."
  (while (and (listp preds)
              (functionp (car preds))
              (funcall (car preds) obj))
    (setq preds (cdr preds)))
  (null preds))

(defun magithub-repo-dir (repo)
  "Data directory for REPO."
  (let-alist repo
    (expand-file-name (format "%s/%s" .owner.login .name)
                      magithub-dir)))

(defconst magithub--object-text-prop-prefix
  "magithub-object-"
  "Prefix used for text properties.
Used for `magithub-thing-at-point' and related functions.")

(defun magithub--object-text-prop (type)
  "Returns a text property symbol for TYPE."
  (intern (concat magithub--object-text-prop-prefix (symbol-name type))))
(defun magithub--object-text-prop-inv (prop)
  "Returns the type referred to by the text property symbol PROP."
  (intern (substring (symbol-name prop) (length magithub--object-text-prop-prefix))))
(defun magithub--object-text-prop-p (prop)
  "Returns non-nil if PROP is a Magithub object text property."
  (s-prefix-p magithub--object-text-prop-prefix (symbol-name prop)))

(defun magithub--object-propertize (type object text)
  "Gives a type-TYPE OBJECT property to TEXT."
  (declare (indent 2))
  (propertize text (magithub--object-text-prop type) object))

(defun magithub-thing-at-point (type)
  "Determine the thing of TYPE at point.
If TYPE is `all', an alist of types to objects is returned."
  (if (eq type 'all)
      (let ((plist (text-properties-at (point))) alist)
        (while plist
          (when (magithub--object-text-prop-p (car plist))
            (thread-first (car plist)
              (magithub--object-text-prop-inv)
              (cons (cadr plist))
              (push alist)))
          (setq plist (cddr plist)))
        alist)
    (get-text-property (point) (magithub--object-text-prop type))))

(defun magithub-get-in-all (props object-list)
  "Follow property-path PROPS in OBJECT-LIST.
Returns a list of the property-values."
  (declare (indent 1))
  (if (or (null props) (not (consp props)))
      object-list
    (magithub-get-in-all (cdr props)
      (mapcar (lambda (o) (alist-get (car props) o))
              object-list))))

(defun magithub-verify-manage-labels (&optional interactive)
  "Verify the user has permission to manage labels.
If the authenticated user does not have permission, an error will
be signaled.

If INTERACTIVE is non-nil, a `user-error' will be raised instead
of a signal (e.g., for interactive forms)."
  (let-alist (magithub-source-repo)
    (if .permissions.push t
      (if interactive
          (user-error "You're not allowed to manage labels in %s" .full_name)
        (signal 'error `(unauthorized manage-labels ,(progn .full_name)))))))

(defun magithub-bug-reference-mode-on ()
  "In GitHub repositories, configure `bug-reference-mode'."
  (interactive)
  (when-let ((repo (magithub-source-repo)))
    (bug-reference-mode 1)
    (setq-local bug-reference-bug-regexp "#\\(?2:[0-9]+\\)")
    (setq-local bug-reference-url-format
                (format "%s/issues/%%s" (alist-get 'html_url repo)))))

(defun magithub-filter-all (funcs list)
  (dolist (f funcs)
    (setq list (cl-remove-if-not f list)))
  list)

(eval-after-load "magit"
  (dolist (hook '(magit-revision-mode-hook git-commit-setup-hook))
    (add-hook hook #'magithub-bug-reference-mode-on)))

(provide 'magithub-core)

;;; We need the cache for `magithub-source-repo', but the cache needs
;;; the core functions as well.  Pretend they're in the same file,
;;; kinda.

;;; See also https://travis-ci.org/vermiculus/magithub/jobs/259008594
(require 'magithub-cache)
;;; magithub-core.el ends here
