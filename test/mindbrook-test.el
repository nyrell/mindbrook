;;; mindbrook-test.el --- Tests for mindbrook  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mindbrook)

(defmacro mindbrook-test--with-dir (&rest body)
  "Run BODY with `mindbrook-dir' bound to a fresh temporary directory."
  (declare (indent 0))
  `(let ((mindbrook-dir (file-name-as-directory (make-temp-file "mindbrook-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory mindbrook-dir t))))

(defmacro mindbrook-test--with-answers (answers &rest body)
  "Run BODY with the prompts of `mindbrook-save-as-scratchpad' stubbed.
ANSWERS is a plist with :action (\"copy\" or \"move\"), :name (a
function from the candidate list to the typed name), :send, :all and
:save (answers to the yes-or-no questions) and :topic (the response of
a stubbed `gptel-request', for mindbrook-ai tests).
The candidates offered are stored in `mindbrook-test--offered'."
  (declare (indent 1))
  `(let ((answers (list ,@answers)))
     (setq mindbrook-test--offered nil)
     (cl-letf (((symbol-function 'read-multiple-choice)
                (lambda (_prompt choices &rest _)
                  (assoc (if (equal (plist-get answers :action) "move") ?m ?c)
                         choices)))
               ((symbol-function 'completing-read)
                (lambda (_prompt candidates &rest _)
                  (setq mindbrook-test--offered candidates)
                  (funcall (or (plist-get answers :name) #'car) candidates)))
               ((symbol-function 'y-or-n-p)
                (lambda (prompt)
                  (plist-get answers (cond ((string-prefix-p "Send" prompt) :send)
                                           ((string-prefix-p "The region" prompt) :all)
                                           (t :save)))))
               ((symbol-function 'gptel-request)
                (lambda (text &rest args)
                  (setq mindbrook-test--sent text)
                  (run-at-time 0.05 nil (plist-get args :callback)
                               (plist-get answers :topic) '(:status "ok")))))
       ,@body)))

(defvar mindbrook-test--offered nil)
(defvar mindbrook-test--sent nil)
(defvar-local mindbrook-test--state nil)

(defun mindbrook-test--file (dir name content)
  "Create file NAME in DIR holding CONTENT and return its name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

(defun mindbrook-test--kill (buf)
  "Kill BUF without asking about unsaved changes."
  (when (buffer-live-p buf)
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)))

(ert-deftest mindbrook-test-sanitize-topic ()
  (should (equal (mindbrook--sanitize-topic "  Rust: borrow/checker?  ")
                 "Rust borrow checker"))
  (should (equal (mindbrook--sanitize-topic "Notes v1.2") "Notes v1 2"))
  (should (equal (mindbrook--sanitize-topic "*scratch*") "scratch"))
  (should-not (mindbrook--sanitize-topic " ... "))
  (should-not (mindbrook--sanitize-topic nil)))

(ert-deftest mindbrook-test-unique-file-name ()
  (mindbrook-test--with-dir
    (should (equal (mindbrook--unique-file-name "2026" "Rust" ".md") "2026 Rust.md"))
    (mindbrook-test--file mindbrook-dir "2026 Rust.md" "")
    (should (equal (mindbrook--unique-file-name "2026" "Rust" ".md") "2026 Rust 2.md"))))

(ert-deftest mindbrook-test-unsaved-buffer-is-saved ()
  "An unsaved buffer is saved under the chosen name, keeping its mode."
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-topic-function (lambda () "Rust: borrow checker"))
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "* Explain the borrow checker")
            (mindbrook-test--with-answers ()
              (mindbrook-save-as-scratchpad))
            (should (equal mindbrook-test--offered
                           '("STAMP Rust borrow checker.org" "STAMP notes.org")))
            (should (equal buffer-file-name
                           (expand-file-name "STAMP Rust borrow checker.org" mindbrook-dir)))
            (should (file-exists-p buffer-file-name))
            (should-not (buffer-modified-p))
            (should (eq major-mode 'org-mode)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-no-topic-suggested ()
  "Without a topic, only the current name is offered."
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP"))
      (dolist (fn (list nil (lambda () nil) (lambda () " ... ")))
        (with-temp-buffer
          (rename-buffer "*notes*" t)
          (insert "text")
          (let ((mindbrook-topic-function fn))
            (mindbrook-test--with-answers (:name (lambda (_) ""))
              (should-error (mindbrook-save-as-scratchpad) :type 'user-error)))
          (should (equal mindbrook-test--offered
                         (list (format "STAMP %s.txt"
                                       (mindbrook--sanitize-topic (buffer-name)))))))))))

(ert-deftest mindbrook-test-unsaved-buffer-keeps-mode ()
  "A buffer with a major mode keeps it, whatever the extension."
  (mindbrook-test--with-dir
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (emacs-lisp-mode)
            (setq-local mindbrook-test--state t)
            (insert "(foo)")
            (mindbrook-test--with-answers ()
              (mindbrook-save-as-scratchpad))
            (should (string-suffix-p ".txt" buffer-file-name))
            (should (eq major-mode 'emacs-lisp-mode))
            (should (local-variable-p 'mindbrook-test--state)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-fundamental-buffer-gets-mode ()
  "A buffer in `fundamental-mode' gets the mode of its new file name."
  (mindbrook-test--with-dir
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "* heading")
            (mindbrook-test--with-answers (:name (lambda (_) "STAMP notes.org"))
              (mindbrook-save-as-scratchpad))
            (should (eq major-mode 'org-mode)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-failed-save-is-undone ()
  (mindbrook-test--with-dir
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (text-mode)                 ;so the hook below is kept
            (insert "text")
            (add-hook 'write-contents-functions (lambda () (error "Disk full")) nil t)
            (mindbrook-test--with-answers ()
              (should-error (mindbrook-save-as-scratchpad)))
            (should-not buffer-file-name)
            (should (equal (buffer-name) "*notes*"))
            (should-not (directory-files mindbrook-dir nil "\\.txt\\'")))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-copy-visits-copy ()
  (mindbrook-test--with-dir
    (let* ((mindbrook-date-format "STAMP")
           (src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src))
           new-buf)
      (unwind-protect
          (with-current-buffer buf
            (mindbrook-test--with-answers (:action "copy")
              (mindbrook-save-as-scratchpad))
            (setq new-buf (current-buffer))
            (should (equal mindbrook-test--offered '("STAMP notes.md")))
            (should (file-exists-p src))
            (should (eq (window-buffer) new-buf))
            (should (equal (buffer-file-name new-buf)
                           (expand-file-name "STAMP notes.md" mindbrook-dir)))
            (should (equal (buffer-file-name buf) src)))
        (mindbrook-test--kill buf)
        (mindbrook-test--kill new-buf)
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-test-move-follows-file ()
  (mindbrook-test--with-dir
    (let* ((mindbrook-date-format "STAMP")
           (src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src)))
      (unwind-protect
          (with-current-buffer buf
            (mindbrook-test--with-answers (:action "move" :name (lambda (_) "STAMP mine.org"))
              (mindbrook-save-as-scratchpad))
            (should-not (file-exists-p src))
            (should (equal buffer-file-name
                           (expand-file-name "STAMP mine.org" mindbrook-dir)))
            (should (file-exists-p buffer-file-name)))
        (mindbrook-test--kill buf)
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-test-unsaved-changes-must-be-saved ()
  (mindbrook-test--with-dir
    (let* ((src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src)))
      (unwind-protect
          (with-current-buffer buf
            (insert "more ")
            (mindbrook-test--with-answers (:save nil)
              (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
            (should (equal (directory-files mindbrook-dir nil "\\.md\\'") nil))
            (mindbrook-test--with-answers (:save t :action "copy")
              (mindbrook-save-as-scratchpad))
            (should (equal (with-temp-buffer
                             (insert-file-contents src)
                             (buffer-string))
                           "more hello")))
        (mindbrook-test--kill buf)
        (mindbrook-test--kill (get-file-buffer
                               (car (directory-files mindbrook-dir t "\\.md\\'"))))
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-test-refuses-file-in-dir ()
  (mindbrook-test--with-dir
    (let ((buf (find-file-noselect (mindbrook-test--file mindbrook-dir "x.md" "x"))))
      (unwind-protect
          (with-current-buffer buf
            (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-refuses-special-buffers ()
  (with-temp-buffer
    (special-mode)
    (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
  (let ((buf (dired-noselect temporary-file-directory)))
    (unwind-protect
        (with-current-buffer buf
          (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest mindbrook-test-refuses-bad-names ()
  (mindbrook-test--with-dir
    (mindbrook-test--file mindbrook-dir "taken.txt" "")
    (with-temp-buffer
      (dolist (name '("" "sub/name.txt" "taken.txt"))
        (mindbrook-test--with-answers (:name (lambda (_) name))
          (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
        (should-not buffer-file-name)))))

(provide 'mindbrook-test)

;;; mindbrook-test.el ends here
