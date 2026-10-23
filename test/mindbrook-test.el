;;; mindbrook-test.el --- Tests for mindbrook  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mindbrook)

(defvar gptel-mode)
(defvar gptel-prompt-prefix-alist)

(defmacro mindbrook-test--with-dir (&rest body)
  "Run BODY with `mindbrook-dir' bound to a fresh temporary directory."
  (declare (indent 0))
  `(let ((mindbrook-dir (file-name-as-directory (make-temp-file "mindbrook-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory mindbrook-dir t))))

(defun mindbrook-test--scratchpad (file content)
  "Return a buffer visiting FILE, already saved once, holding CONTENT.
The buffer is set up like `mindbrook-new-gptel-agent' leaves one."
  (with-temp-file file)
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (insert content)
      (add-hook 'before-save-hook #'mindbrook--gptel-name-on-save -50 t))
    buf))

(defun mindbrook-test--async-request (response)
  "Return a `gptel-request' stand-in that answers RESPONSE asynchronously."
  (lambda (&rest args)
    (let ((callback (plist-get (cdr args) :callback)))
      (run-at-time 0.05 nil callback response '(:status "ok")))))

(ert-deftest mindbrook-test-sanitize-topic ()
  (should (equal (mindbrook--sanitize-topic "  Rust: borrow/checker?  ")
                 "Rust borrow checker"))
  (should (equal (mindbrook--sanitize-topic "Notes v1.2") "Notes v1 2"))
  (should-not (mindbrook--sanitize-topic " ... "))
  (should-not (mindbrook--sanitize-topic nil)))

(ert-deftest mindbrook-test-conversation-skips-local-variables ()
  (with-temp-buffer
    (insert "### hello\n\nanswer\n\n<!-- Local Variables: -->\n"
            "<!-- gptel-model: m -->\n<!-- End: -->\n")
    (should (equal (mindbrook--gptel-conversation) "### hello\n\nanswer"))))

(ert-deftest mindbrook-test-has-conversation ()
  (let ((gptel-prompt-prefix-alist '((markdown-mode . "### "))))
    (should-not (mindbrook--gptel-has-conversation-p "###"))
    (should-not (mindbrook--gptel-has-conversation-p ""))
    (should (mindbrook--gptel-has-conversation-p "### hello"))))

(ert-deftest mindbrook-test-topic-file-name-avoids-existing ()
  (mindbrook-test--with-dir
    (let ((file (expand-file-name "2026-10-23 101010 gptel-agent.md" mindbrook-dir)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (should (equal (mindbrook--gptel-topic-file-name "Rust")
                       (expand-file-name "2026-10-23 101010 Rust.md" mindbrook-dir)))
        (with-temp-file (expand-file-name "2026-10-23 101010 Rust.md" mindbrook-dir))
        (should (equal (mindbrook--gptel-topic-file-name "Rust")
                       (expand-file-name "2026-10-23 101010 Rust 2.md" mindbrook-dir)))
        (setq buffer-file-name nil)))))

(ert-deftest mindbrook-test-first-save-renames-in-place ()
  "The first save renames the file to the AI topic; no copy is left behind."
  (mindbrook-test--with-dir
    (let* ((old (expand-file-name "2026-10-23 101010 gptel-agent.md" mindbrook-dir))
           (new (expand-file-name "2026-10-23 101010 Rust borrow checker.md" mindbrook-dir))
           (buf (mindbrook-test--scratchpad old "### Explain the borrow checker\n\nIt..."))
           (offered nil))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-request)
                     (mindbrook-test--async-request "Rust borrow checker\n"))
                    ((symbol-function 'read-string)
                     (lambda (_prompt initial) (setq offered initial) initial)))
            (with-current-buffer buf
              (save-buffer)
              (should (equal offered "Rust borrow checker"))
              (should (equal buffer-file-name new))
              (should (file-exists-p new))
              (should-not (file-exists-p old))
              (should (equal (directory-files mindbrook-dir nil "\\.md\\'")
                             (list (file-name-nondirectory new))))
              (should-not (memq #'mindbrook--gptel-name-on-save before-save-hook))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest mindbrook-test-user-can-edit-topic ()
  (mindbrook-test--with-dir
    (let* ((old (expand-file-name "2026-10-23 101010 gptel-agent.md" mindbrook-dir))
           (buf (mindbrook-test--scratchpad old "### hello")))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-request)
                     (mindbrook-test--async-request "Greeting"))
                    ((symbol-function 'read-string)
                     (lambda (_prompt _initial) "My own name")))
            (with-current-buffer buf
              (save-buffer)
              (should (equal (file-name-nondirectory buffer-file-name)
                             "2026-10-23 101010 My own name.md"))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest mindbrook-test-empty-buffer-keeps-placeholder ()
  (mindbrook-test--with-dir
    (let* ((old (expand-file-name "2026-10-23 101010 gptel-agent.md" mindbrook-dir))
           (buf (mindbrook-test--scratchpad old "### "))
           (gptel-prompt-prefix-alist '((markdown-mode . "### ")))
           (requested nil))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (&rest _) (setq requested t))))
            (with-current-buffer buf
              (save-buffer)
              (should-not requested)
              (should (equal buffer-file-name old))
              (should (memq #'mindbrook--gptel-name-on-save before-save-hook))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest mindbrook-test-failed-request-asks-again-later ()
  "A failed request and an empty answer keep the placeholder for now."
  (mindbrook-test--with-dir
    (let* ((old (expand-file-name "2026-10-23 101010 gptel-agent.md" mindbrook-dir))
           (buf (mindbrook-test--scratchpad old "### hello"))
           (offered 'unset))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-request)
                     (mindbrook-test--async-request nil))
                    ((symbol-function 'read-string)
                     (lambda (_prompt initial) (setq offered initial) "")))
            (with-current-buffer buf
              (save-buffer)
              (should-not offered)
              (should (equal buffer-file-name old))
              (should (file-exists-p old))
              (should (memq #'mindbrook--gptel-name-on-save before-save-hook))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest mindbrook-test-new-agent-visits-scratchpad ()
  "The new command finds the agent buffer even though `gptel-agent'
returns its header-line form instead of the buffer."
  (mindbrook-test--with-dir
    (let (agent-buf buf)
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-agent)
                     (lambda (&rest _)
                       (interactive)
                       (setq agent-buf (generate-new-buffer "*gptel-agent:test*"))
                       (with-current-buffer agent-buf
                         (setq-local gptel-mode t))
                       '(:eval (funcall ignore))))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (setq buf (mindbrook-new-gptel-agent))
            (should (eq buf agent-buf))
            (with-current-buffer buf
              (should (equal (file-name-directory buffer-file-name)
                             (expand-file-name mindbrook-dir)))
              (should (string-suffix-p " gptel-agent.md" buffer-file-name))
              (should (memq #'mindbrook--gptel-name-on-save before-save-hook))))
        (when (buffer-live-p agent-buf) (kill-buffer agent-buf))))))

(provide 'mindbrook-test)

;;; mindbrook-test.el ends here
