;;; mindbrook-save-test.el --- Tests for mindbrook-save  -*- lexical-binding: t; -*-

;;; Commentary:

;; gptel is not needed; `gptel-request' and `gptel-abort' are stubbed.
;; Run with:
;;
;;   emacs -Q --batch -L . -L test -l test/mindbrook-save-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mindbrook-save)
(require 'mindbrook-test)

(defvar gptel-backend nil)
(defvar gptel-model nil)
(defvar gptel-use-tools nil)

(defvar mindbrook-save-test--offered nil
  "The file name candidates offered by the last stubbed prompt.")
(defvar mindbrook-save-test--sent nil
  "The text sent by the last stubbed `gptel-request'.")
(defvar-local mindbrook-save-test--state nil
  "Buffer-local state that must survive saving.")
(defvar mindbrook-save-test--failures nil
  "The reasons given for missing AI topics, latest first.")

(defmacro mindbrook-save-test--with-answers (answers &rest body)
  "Run BODY with stubbed answers for `mindbrook-save-as-scratchpad'.
ANSWERS is a plist with :action (\"copy\" or \"move\"), :name (a
function from the candidate list to the typed name), :send, :all and
:save (answers to the yes-or-no questions) and :topic (the response of
the stubbed `gptel-request').  gptel counts as loaded in BODY, and the
reasons for missing AI topics are collected in
`mindbrook-save-test--failures'."
  (declare (indent 1))
  (let ((plist (make-symbol "answers"))
        (loaded (make-symbol "loaded")))
    `(let ((,plist (list ,@answers))
           (,loaded (featurep 'gptel-request)))
       (setq mindbrook-save-test--offered nil
             mindbrook-save-test--failures nil)
       (provide 'gptel-request)
       (unwind-protect
           (cl-letf (((symbol-function 'read-multiple-choice)
                      (lambda (_prompt choices &rest _)
                        (assoc (if (equal (plist-get ,plist :action) "move") ?m ?c)
                               choices)))
                     ((symbol-function 'completing-read)
                      (lambda (_prompt candidates &rest _)
                        (setq mindbrook-save-test--offered candidates)
                        (funcall (or (plist-get ,plist :name) #'car) candidates)))
                     ((symbol-function 'y-or-n-p)
                      (lambda (prompt)
                        (plist-get ,plist (cond ((string-prefix-p "Send" prompt) :send)
                                                ((string-prefix-p "The region" prompt) :all)
                                                (t :save)))))
                     ((symbol-function 'mindbrook-save--ai-failed)
                      (lambda (format-string &rest args)
                        (push (apply #'format-message format-string args)
                              mindbrook-save-test--failures)
                        nil))
                     ((symbol-function 'gptel-request)
                      (lambda (text &rest args)
                        (setq mindbrook-save-test--sent text)
                        (run-at-time 0.05 nil (plist-get args :callback)
                                     (plist-get ,plist :topic) '(:status "ok")))))
             ,@body)
         (unless ,loaded
           (setq features (delq 'gptel-request features)))))))

(defmacro mindbrook-save-test--with-region (beg end &rest body)
  "Run BODY with the region from BEG to END active."
  (declare (indent 2))
  `(let ((transient-mark-mode t))
     (set-mark ,beg)
     (goto-char ,end)
     (activate-mark)
     ,@body))

;;;; AI topic suggestions

(ert-deftest mindbrook-save-test-ai-text ()
  (let ((mindbrook-save-ai-context-size 5))
    (with-temp-buffer
      (mindbrook-save-test--with-answers (:send t)
        (should-not (mindbrook-save--ai-text))
        (insert "  \n\t ")
        (should-not (mindbrook-save--ai-text))
        (erase-buffer)
        (insert "abcdefghij")
        (should (equal (mindbrook-save--ai-text) "abcde"))
        (mindbrook-save-test--with-region 4 6
          (should (equal (mindbrook-save--ai-text) "de")))))))

(ert-deftest mindbrook-save-test-long-buffer-is-cut-without-asking ()
  (let ((mindbrook-save-ai-context-size 3)
        (asked nil))
    (with-temp-buffer
      (insert "abcdefghij")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) t)))
        (should (equal (mindbrook-save--ai-text) "abc")))
      (should (= (length asked) 1))
      (should (string-prefix-p "Send 3 characters" (car asked))))))

(ert-deftest mindbrook-save-test-long-region-asks-after-consent ()
  "A region over the limit is sent whole only if the user agrees."
  (let ((mindbrook-save-ai-context-size 3)
        (asked nil))
    (with-temp-buffer
      (insert "abcdefghij")
      (mindbrook-save-test--with-region 2 9
        (mindbrook-save-test--with-answers (:send t :all t)
          (should (equal (mindbrook-save--ai-text) "bcdefgh")))
        (mindbrook-save-test--with-answers (:send t :all nil)
          (should (equal (mindbrook-save--ai-text) "bcd")))
        ;; Declining to send anything asks nothing more.
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt) (push prompt asked) nil)))
          (should-not (mindbrook-save--ai-text)))
        (should (equal (length asked) 1))
        (should (string-prefix-p "Send 3 characters of the region" (car asked)))
        (should (string-match-p "region is 7 characters, over the limit of 3"
                                (let (prompt)
                                  (cl-letf (((symbol-function 'y-or-n-p)
                                             (lambda (p) (setq prompt p) t)))
                                    (mindbrook-save--ai-text))
                                  prompt)))))
    (with-temp-buffer
      (insert "abcdefghij")
      (mindbrook-save-test--with-region 2 4
        (mindbrook-save-test--with-answers (:send t :all 'unexpected)
          (should (equal (mindbrook-save--ai-text) "bc")))))))

(ert-deftest mindbrook-save-test-ai-text-without-asking ()
  "With `mindbrook-save-ai-topic' t the text is sent without asking."
  (let ((mindbrook-save-ai-topic t))
    (with-temp-buffer
      (insert "abc")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked"))))
        (should (equal (mindbrook-save--ai-text) "abc"))))))

(ert-deftest mindbrook-save-test-ai-usable ()
  (should (equal (mindbrook-save--ai-usable "  Rust borrow checker \n") "Rust borrow checker"))
  (should-not (mindbrook-save--ai-usable nil))
  (should-not (mindbrook-save--ai-usable "  "))
  (should-not (mindbrook-save--ai-usable "Yes.\n\nSSH just runs a remote command"))
  (should-not (mindbrook-save--ai-usable (make-string 81 ?x))))

(ert-deftest mindbrook-save-test-ai-failed ()
  "A failure is reported, and the topic is nil."
  (let (shown)
    (cl-letf (((symbol-function 'sit-for) #'ignore)
              ((symbol-function 'message)
               (lambda (&rest args) (setq shown (apply #'format-message args)))))
      (should-not (mindbrook-save--ai-failed "no answer within %s seconds" 10)))
    (should (equal shown "No AI topic suggestion: no answer within 10 seconds"))))

(ert-deftest mindbrook-save-test-request-uses-own-buffer ()
  "The request runs in a buffer of its own.
That buffer has the given backend and model and tools disabled, and the
text is marked off."
  (let ((mindbrook-save-ai-timeout 5)
        seen sent)
    (with-temp-buffer
      (setq-local gptel-use-tools t)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (text &rest args)
                   (let ((buf (plist-get args :buffer)))
                     (setq sent text
                           seen (list buf
                                      (buffer-local-value 'gptel-backend buf)
                                      (buffer-local-value 'gptel-model buf)
                                      (buffer-local-value 'gptel-use-tools buf))))
                   (funcall (plist-get args :callback) "Topic\n" nil))))
        (should (equal (mindbrook-save--ai-request "text" 'my-backend 'my-model)
                       "Topic"))
        (should (equal sent "<text>\ntext\n</text>"))
        (should-not (eq (car seen) (current-buffer)))
        (should-not (buffer-live-p (car seen)))
        (should (equal (cdr seen) '(my-backend my-model nil)))))))

(defmacro mindbrook-save-test--request (&rest body)
  "Run BODY with failures collected in `mindbrook-save-test--failures'."
  (declare (indent 0))
  `(progn
     (setq mindbrook-save-test--failures nil)
     (cl-letf (((symbol-function 'mindbrook-save--ai-failed)
                (lambda (format-string &rest args)
                  (push (apply #'format-message format-string args)
                        mindbrook-save-test--failures)
                  nil)))
       ,@body)))

(ert-deftest mindbrook-save-test-unusable-answer-is-not-used ()
  "An answer that is not a topic is reported, never cut to its first line."
  (mindbrook-save-test--request
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_text &rest args)
                 (funcall (plist-get args :callback)
                          "Yes. SSH just runs a remote command:\n\nssh host tail" nil))))
      (should-not (mindbrook-save--ai-request "text" nil nil)))
    (should (string-prefix-p "unusable answer from gptel: Yes. SSH"
                             (car mindbrook-save-test--failures)))))

(ert-deftest mindbrook-save-test-timeout-aborts-request ()
  (let ((mindbrook-save-ai-timeout 0.2)
        req aborted)
    (mindbrook-save-test--request
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_text &rest args)
                   (setq req args)))
                ((symbol-function 'gptel-abort)
                 (lambda (buf)
                   (setq aborted buf)
                   ;; As gptel does, tell the callback.
                   (funcall (plist-get req :callback) 'abort nil))))
        (should-not (mindbrook-save--ai-request "text" nil nil))
        (should (eq aborted (plist-get req :buffer)))))
    (should (equal mindbrook-save-test--failures '("no answer within 0.2 seconds")))))

(ert-deftest mindbrook-save-test-quit-while-waiting-skips-topic ()
  "\\[keyboard-quit] while waiting for a topic only skips the suggestion."
  (let (aborted)
    (mindbrook-save-test--request
      (cl-letf (((symbol-function 'gptel-request) #'ignore)
                ((symbol-function 'gptel-abort) (lambda (_) (setq aborted t)))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) (signal 'quit nil))))
        (should-not (mindbrook-save--ai-request "text" nil nil))
        (should aborted)))
    (should (equal mindbrook-save-test--failures '("cancelled")))))

(ert-deftest mindbrook-save-test-failing-request-skips-topic ()
  (let (aborted)
    (mindbrook-save-test--request
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (&rest _) (error "No API key")))
                ((symbol-function 'gptel-abort) (lambda (_) (setq aborted t))))
        (should-not (mindbrook-save--ai-request "text" nil nil))
        (should-not aborted)))
    (should (equal mindbrook-save-test--failures '("gptel failed: No API key")))))

(ert-deftest mindbrook-save-test-error-response-skips-topic ()
  (mindbrook-save-test--request
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_text &rest args)
                 (funcall (plist-get args :callback) nil '(:status "HTTP 401")))))
      (should-not (mindbrook-save--ai-request "text" nil nil)))
    (should (equal mindbrook-save-test--failures '("gptel failed: HTTP 401")))))

(ert-deftest mindbrook-save-test-ai-model ()
  "The backend and model come from the options, or else from gptel."
  (let ((gptel-backend 'current-backend)
        (gptel-model 'current-model))
    (cl-letf (((symbol-function 'gptel-get-backend)
               (lambda (name)
                 (if (equal name "Ollama") 'ollama (user-error "Unknown %s" name))))
              ((symbol-function 'gptel-backend-models)
               (lambda (_backend) '(llama3.2 mistral))))
      (let ((mindbrook-save-ai-backend nil) (mindbrook-save-ai-model nil))
        (should (equal (mindbrook-save--ai-model) '(current-backend . current-model))))
      (let ((mindbrook-save-ai-backend nil) (mindbrook-save-ai-model 'other))
        (should (equal (mindbrook-save--ai-model) '(current-backend . other))))
      (let ((mindbrook-save-ai-backend "Ollama") (mindbrook-save-ai-model nil))
        (should (equal (mindbrook-save--ai-model) '(ollama . llama3.2))))
      (let ((mindbrook-save-ai-backend "Ollama") (mindbrook-save-ai-model 'mistral))
        (should (equal (mindbrook-save--ai-model) '(ollama . mistral))))
      (let ((mindbrook-save-ai-backend "Nope"))
        (should-error (mindbrook-save--ai-model) :type 'user-error)))))

(ert-deftest mindbrook-save-test-unknown-backend-sends-nothing ()
  (let ((mindbrook-save-ai-topic 'ask)
        (mindbrook-save-ai-backend "Nope"))
    (with-temp-buffer
      (insert "secret")
      (setq mindbrook-save-test--sent nil)
      (mindbrook-save-test--with-answers (:send t :topic "Leak")
        (cl-letf (((symbol-function 'gptel-get-backend)
                   (lambda (name) (user-error "Backend %s is not known" name))))
          (should-not (mindbrook-save--ai-topic))))
      (should-not mindbrook-save-test--sent)
      (should (equal mindbrook-save-test--failures '("Backend Nope is not known"))))))

(ert-deftest mindbrook-save-test-gptel-not-loaded ()
  "Without gptel loaded nothing is asked or sent, and gptel is not loaded.
An autoload for `gptel-request' must not count as gptel being loaded."
  (should-not (featurep 'gptel-request))
  (let ((mindbrook-save-ai-topic 'ask)
        (asked nil))
    (unwind-protect
        (progn
          (autoload 'gptel-request "mindbrook-save-test-no-such-library")
          (with-temp-buffer
            (insert "text")
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (&rest _) (setq asked t))))
              (should-not (mindbrook-save--ai-topic))))
          (should-not asked)
          (should (autoloadp (symbol-function 'gptel-request))))
      (fmakunbound 'gptel-request))))

(ert-deftest mindbrook-save-test-ai-off-asks-nothing ()
  (let ((mindbrook-save-ai-topic nil))
    (with-temp-buffer
      (insert "secret")
      (setq mindbrook-save-test--sent nil)
      (mindbrook-save-test--with-answers (:send t :topic "Leak")
        (should-not (mindbrook-save--ai-topic)))
      (should-not mindbrook-save-test--sent))))

;;;; Saving buffers as scratchpads

(ert-deftest mindbrook-save-test-unsaved-buffer-is-saved ()
  "An unsaved buffer is saved under the chosen name, keeping its mode."
  (mindbrook-test--with-dirs
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-save-ai-topic 'ask)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "* Explain the borrow checker")
            (mindbrook-save-test--with-answers (:send t :topic "Rust: borrow checker\n")
              (mindbrook-save-as-scratchpad))
            (should (equal mindbrook-save-test--sent
                           "<text>\n* Explain the borrow checker\n</text>"))
            (should (equal mindbrook-save-test--offered
                           '("STAMP Rust borrow checker.org" "STAMP notes.org")))
            (should (equal buffer-file-name
                           (expand-file-name "STAMP Rust borrow checker.org" mindbrook-dir)))
            (should (file-exists-p buffer-file-name))
            (should-not (buffer-modified-p))
            (should (eq major-mode 'org-mode)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-no-topic-suggested ()
  "Without a topic, only the current name is offered."
  (mindbrook-test--with-dirs
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-save-ai-topic 'ask))
      (dolist (answers '((:send nil :topic "Leak")
                         (:send t :topic nil)
                         (:send t :topic " ... ")))
        (with-temp-buffer
          (rename-buffer "*notes*" t)
          (insert "text")
          (mindbrook-save-test--with-answers (:send (plist-get answers :send)
                                                    :topic (plist-get answers :topic)
                                                    :name (lambda (_) ""))
            (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
          (should (equal mindbrook-save-test--offered
                         (list (format "STAMP %s.txt"
                                       (mindbrook--sanitize-topic (buffer-name)))))))))))

(ert-deftest mindbrook-save-test-blank-buffer-sends-nothing ()
  (mindbrook-test--with-dirs
    (let ((mindbrook-save-ai-topic 'ask)
          (asked nil)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "  \n ")
            (setq mindbrook-save-test--sent nil)
            (mindbrook-save-test--with-answers (:send t :topic "Nothing")
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (setq asked t))))
                (mindbrook-save-as-scratchpad)))
            (should-not asked)
            (should-not mindbrook-save-test--sent))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-unsaved-buffer-keeps-mode ()
  "A buffer with a major mode keeps it, whatever the extension."
  (mindbrook-test--with-dirs
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (emacs-lisp-mode)
            (setq mindbrook-save-test--state t)
            (insert "(foo)")
            (mindbrook-save-test--with-answers ()
              (mindbrook-save-as-scratchpad))
            (should (string-suffix-p ".txt" buffer-file-name))
            (should (eq major-mode 'emacs-lisp-mode))
            (should mindbrook-save-test--state))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-fundamental-buffer-gets-mode ()
  "A buffer in `fundamental-mode' gets the mode of its new file name."
  (mindbrook-test--with-dirs
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (insert "* heading")
            (mindbrook-save-test--with-answers (:name (lambda (_) "STAMP notes.org"))
              (mindbrook-save-as-scratchpad))
            (should (eq major-mode 'org-mode)))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-failed-save-is-undone ()
  (mindbrook-test--with-dirs
    (let ((buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (text-mode)                 ;so the hook below is kept
            (insert "text")
            (add-hook 'write-contents-functions (lambda () (error "Disk full")) nil t)
            (mindbrook-save-test--with-answers ()
              (should-error (mindbrook-save-as-scratchpad)))
            (should-not buffer-file-name)
            (should (equal (buffer-name) "*notes*"))
            (should-not (directory-files mindbrook-dir nil "\\.txt\\'")))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-copy-visits-copy ()
  (mindbrook-test--with-dirs
    (let* ((mindbrook-date-format "STAMP")
           (src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src))
           new-buf)
      (unwind-protect
          (with-current-buffer buf
            (mindbrook-save-test--with-answers (:action "copy")
              (mindbrook-save-as-scratchpad))
            (setq new-buf (current-buffer))
            (should (equal mindbrook-save-test--offered '("STAMP notes.md")))
            (should (file-exists-p src))
            (should (eq (window-buffer) new-buf))
            (should (equal (buffer-file-name new-buf)
                           (expand-file-name "STAMP notes.md" mindbrook-dir)))
            (should (equal (buffer-file-name buf) src)))
        (mindbrook-test--kill buf)
        (mindbrook-test--kill new-buf)
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-save-test-move-follows-file ()
  (mindbrook-test--with-dirs
    (let* ((mindbrook-date-format "STAMP")
           (src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src)))
      (unwind-protect
          (with-current-buffer buf
            (mindbrook-save-test--with-answers (:action "move"
                                                        :name (lambda (_) "STAMP mine.org"))
              (mindbrook-save-as-scratchpad))
            (should-not (file-exists-p src))
            (should (equal buffer-file-name
                           (expand-file-name "STAMP mine.org" mindbrook-dir)))
            (should (file-exists-p buffer-file-name)))
        (mindbrook-test--kill buf)
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-save-test-unsaved-changes-must-be-saved ()
  (mindbrook-test--with-dirs
    (let* ((src-dir (make-temp-file "mindbrook-src-" t))
           (src (mindbrook-test--file src-dir "notes.md" "hello"))
           (buf (find-file-noselect src)))
      (unwind-protect
          (with-current-buffer buf
            (insert "more ")
            (mindbrook-save-test--with-answers (:save nil)
              (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
            (should-not (directory-files mindbrook-dir nil "\\.md\\'"))
            (mindbrook-save-test--with-answers (:save t :action "copy")
              (mindbrook-save-as-scratchpad))
            (should (equal (with-temp-buffer
                             (insert-file-contents src)
                             (buffer-string))
                           "more hello")))
        (mindbrook-test--kill buf)
        (mindbrook-test--kill (get-file-buffer
                               (car (directory-files mindbrook-dir t "\\.md\\'"))))
        (delete-directory src-dir t)))))

(ert-deftest mindbrook-save-test-refuses-file-in-dir ()
  (mindbrook-test--with-dirs
    (let ((buf (find-file-noselect (mindbrook-test--file mindbrook-dir "x.md" "x"))))
      (unwind-protect
          (with-current-buffer buf
            (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-save-test-refuses-special-buffers ()
  (with-temp-buffer
    (special-mode)
    (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
  (let ((buf (dired-noselect temporary-file-directory)))
    (unwind-protect
        (with-current-buffer buf
          (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest mindbrook-save-test-refuses-bad-names ()
  (mindbrook-test--with-dirs
    (mindbrook-test--file mindbrook-dir "taken.txt" "")
    (with-temp-buffer
      (dolist (name '("" "sub/name.txt" "taken.txt"))
        (mindbrook-save-test--with-answers (:name (lambda (_) name))
          (should-error (mindbrook-save-as-scratchpad) :type 'user-error))
        (should-not buffer-file-name)))))

(provide 'mindbrook-save-test)

;;; mindbrook-save-test.el ends here
