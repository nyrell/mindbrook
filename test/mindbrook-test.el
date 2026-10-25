;;; mindbrook-test.el --- Tests for mindbrook  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mindbrook)

(defvar gptel-use-tools)

(defmacro mindbrook-test--with-dir (&rest body)
  "Run BODY with `mindbrook-dir' bound to a fresh temporary directory."
  (declare (indent 0))
  `(let ((mindbrook-dir (file-name-as-directory (make-temp-file "mindbrook-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory mindbrook-dir t))))

(defmacro mindbrook-test--with-answers (answers &rest body)
  "Run BODY with the prompts of `mindbrook-save-as-scratchpad' stubbed.
ANSWERS is a plist with :action (\"copy\" or \"move\"), :name (a
function from the candidate list to the typed name), :send and :save
\(answers to the yes-or-no questions) and :topic (the gptel response).
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
                  (plist-get answers (if (string-prefix-p "Send" prompt)
                                         :send :save))))
               ((symbol-function 'gptel-request)
                (lambda (text &rest args)
                  (setq mindbrook-test--sent text)
                  (run-at-time 0.05 nil (plist-get args :callback)
                               (plist-get answers :topic) '(:status "ok")))))
       ,@body)))

(defvar mindbrook-test--offered nil)
(defvar mindbrook-test--sent nil)

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

(ert-deftest mindbrook-test-topic-text ()
  (let ((mindbrook-ai-topic-context-size 5))
    (with-temp-buffer
      (should-not (mindbrook--topic-text))
      (insert "  \n\t ")
      (should-not (mindbrook--topic-text))
      (erase-buffer)
      (insert "abcdefghij")
      (should (equal (mindbrook--topic-text) "abcde"))
      (let ((transient-mark-mode t))
        (set-mark 4)
        (goto-char 6)
        (activate-mark)
        (should (equal (mindbrook--topic-text) "de"))))))

(ert-deftest mindbrook-test-unsaved-buffer-is-saved ()
  "An unsaved buffer is saved under the chosen name, keeping its mode."
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-ai-topic 'ask)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "* Explain the borrow checker")
            (mindbrook-test--with-answers (:send t :topic "Rust borrow checker\n")
              (mindbrook-save-as-scratchpad))
            (should (equal mindbrook-test--offered
                           '("STAMP Rust borrow checker.org" "STAMP notes.org")))
            (should (equal buffer-file-name
                           (expand-file-name "STAMP Rust borrow checker.org" mindbrook-dir)))
            (should (file-exists-p buffer-file-name))
            (should-not (buffer-modified-p))
            (should (eq major-mode 'org-mode)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-ai-off-sends-nothing ()
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-ai-topic nil)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "secret")
            (setq mindbrook-test--sent nil)
            (mindbrook-test--with-answers (:send t :topic "Leak")
              (mindbrook-save-as-scratchpad))
            (should-not mindbrook-test--sent)
            (should (equal mindbrook-test--offered '("STAMP notes.txt"))))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-declined-send-sends-nothing ()
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-ai-topic 'ask)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "secret")
            (setq mindbrook-test--sent nil)
            (mindbrook-test--with-answers (:send nil :topic "Leak")
              (mindbrook-save-as-scratchpad))
            (should-not mindbrook-test--sent)
            (should (equal mindbrook-test--offered '("STAMP notes.txt"))))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-blank-buffer-sends-nothing ()
  (mindbrook-test--with-dir
    (let ((mindbrook-ai-topic 'ask)
          (asked nil)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "  \n ")
            (setq mindbrook-test--sent nil)
            (mindbrook-test--with-answers (:send t :topic "Nothing")
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (setq asked t))))
                (mindbrook-save-as-scratchpad)))
            (should-not asked)
            (should-not mindbrook-test--sent))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-request-disables-tools ()
  (let ((mindbrook-ai-topic-timeout 5)
        (gptel-use-tools t)
        tools)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_text &rest args)
                 (setq tools gptel-use-tools)
                 (funcall (plist-get args :callback) "Topic" nil))))
      (should (equal (mindbrook--request-topic "text") "Topic"))
      (should-not tools))))

(ert-deftest mindbrook-test-quit-while-waiting-skips-topic ()
  "\\[keyboard-quit] while waiting for a topic only skips the suggestion."
  (cl-letf (((symbol-function 'gptel-request) #'ignore)
            ((symbol-function 'accept-process-output)
             (lambda (&rest _) (signal 'quit nil))))
    (should-not (mindbrook--request-topic "text"))))

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
