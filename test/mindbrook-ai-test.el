;;; mindbrook-ai-test.el --- Tests for mindbrook-ai  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mindbrook-ai)
(require 'mindbrook-test)

;; gptel is stubbed out; `gptel-request' is only bound inside
;; `mindbrook-test--with-answers' and the tests below.
(defvar gptel-backend nil)
(defvar gptel-model nil)
(defvar gptel-use-tools nil)

(defmacro mindbrook-ai-test--with-region (beg end &rest body)
  "Run BODY with the region from BEG to END active."
  (declare (indent 2))
  `(let ((transient-mark-mode t))
     (set-mark ,beg)
     (goto-char ,end)
     (activate-mark)
     ,@body))

(ert-deftest mindbrook-ai-test-text ()
  (let ((mindbrook-ai-context-size 5))
    (with-temp-buffer
      (mindbrook-test--with-answers (:send t)
        (should-not (mindbrook-ai--text))
        (insert "  \n\t ")
        (should-not (mindbrook-ai--text))
        (erase-buffer)
        (insert "abcdefghij")
        (should (equal (mindbrook-ai--text) "abcde"))
        (mindbrook-ai-test--with-region 4 6
          (should (equal (mindbrook-ai--text) "de")))))))

(ert-deftest mindbrook-ai-test-long-buffer-is-cut-without-asking ()
  (let ((mindbrook-ai-context-size 3)
        (asked nil))
    (with-temp-buffer
      (insert "abcdefghij")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) t)))
        (should (equal (mindbrook-ai--text) "abc")))
      (should (= (length asked) 1))
      (should (string-prefix-p "Send 3 characters" (car asked))))))

(ert-deftest mindbrook-ai-test-long-region-asks-after-consent ()
  "A region over the limit is sent whole only if the user agrees."
  (let ((mindbrook-ai-context-size 3)
        (asked nil))
    (with-temp-buffer
      (insert "abcdefghij")
      (mindbrook-ai-test--with-region 2 9
        (mindbrook-test--with-answers (:send t :all t)
          (should (equal (mindbrook-ai--text) "bcdefgh")))
        (mindbrook-test--with-answers (:send t :all nil)
          (should (equal (mindbrook-ai--text) "bcd")))
        ;; Declining to send anything asks nothing more.
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt) (push prompt asked) nil)))
          (should-not (mindbrook-ai--text)))
        (should (equal (length asked) 1))
        (should (string-prefix-p "Send 3 characters of the region" (car asked)))
        (should (string-match-p "region is 7 characters, over the limit of 3"
                                (let (prompt)
                                  (cl-letf (((symbol-function 'y-or-n-p)
                                             (lambda (p) (setq prompt p) t)))
                                    (mindbrook-ai--text))
                                  prompt)))))
    (with-temp-buffer
      (insert "abcdefghij")
      (mindbrook-ai-test--with-region 2 4
        (mindbrook-test--with-answers (:send t :all 'unexpected)
          (should (equal (mindbrook-ai--text) "bc")))))))

(ert-deftest mindbrook-ai-test-request-uses-own-buffer ()
  "The request runs in a buffer of its own, with the backend and model
of the current buffer and tools disabled."
  (let ((mindbrook-ai-timeout 5)
        seen)
    (with-temp-buffer
      (setq-local gptel-backend 'my-backend)
      (setq-local gptel-model 'my-model)
      (setq-local gptel-use-tools t)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_text &rest args)
                   (let ((buf (plist-get args :buffer)))
                     (setq seen (list buf
                                      (buffer-local-value 'gptel-backend buf)
                                      (buffer-local-value 'gptel-model buf)
                                      (buffer-local-value 'gptel-use-tools buf))))
                   (funcall (plist-get args :callback) "Topic\nmore" nil))))
        (should (equal (mindbrook-ai--request "text") "Topic"))
        (should-not (eq (car seen) (current-buffer)))
        (should-not (buffer-live-p (car seen)))
        (should (equal (cdr seen) '(my-backend my-model nil)))))))

(ert-deftest mindbrook-ai-test-timeout-aborts-request ()
  (let ((mindbrook-ai-timeout 0.2)
        req aborted)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_text &rest args) (setq req (plist-get args :buffer))))
              ((symbol-function 'gptel-abort)
               (lambda (buf) (setq aborted buf))))
      (should-not (mindbrook-ai--request "text"))
      (should (eq aborted req)))))

(ert-deftest mindbrook-ai-test-quit-while-waiting-skips-topic ()
  "\\[keyboard-quit] while waiting for a topic only skips the suggestion."
  (let (aborted)
    (cl-letf (((symbol-function 'gptel-request) #'ignore)
              ((symbol-function 'gptel-abort) (lambda (_) (setq aborted t)))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _) (signal 'quit nil))))
      (should-not (mindbrook-ai--request "text"))
      (should aborted))))

(ert-deftest mindbrook-ai-test-failing-request-skips-topic ()
  (let (aborted)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (&rest _) (error "No API key")))
              ((symbol-function 'gptel-abort) (lambda (_) (setq aborted t))))
      (should-not (mindbrook-ai--request "text"))
      (should-not aborted))))

(ert-deftest mindbrook-ai-test-gptel-not-loaded ()
  "Without gptel loaded nothing is asked, sent or loaded."
  (should-not (fboundp 'gptel-request))
  (let ((asked nil)
        (required nil))
    (with-temp-buffer
      (insert "text")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked t)))
                ((symbol-function 'require)
                 (lambda (feature &rest _) (setq required feature))))
        (should-not (mindbrook-ai-topic))))
    (should-not asked)
    (should-not required)))

(ert-deftest mindbrook-ai-test-save-with-topic ()
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-topic-function #'mindbrook-ai-topic)
          (buf (generate-new-buffer "*notes*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "* Explain the borrow checker")
            (mindbrook-test--with-answers (:send t :topic "Rust: borrow checker\n")
              (mindbrook-save-as-scratchpad))
            (should (equal mindbrook-test--sent "* Explain the borrow checker"))
            (should (equal (file-name-nondirectory buffer-file-name)
                           "STAMP Rust borrow checker.org")))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-ai-test-declined-send-sends-nothing ()
  (mindbrook-test--with-dir
    (let ((mindbrook-date-format "STAMP")
          (mindbrook-topic-function #'mindbrook-ai-topic)
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

(ert-deftest mindbrook-ai-test-blank-buffer-sends-nothing ()
  (mindbrook-test--with-dir
    (let ((mindbrook-topic-function #'mindbrook-ai-topic)
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

(provide 'mindbrook-ai-test)

;;; mindbrook-ai-test.el ends here
