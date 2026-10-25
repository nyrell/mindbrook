;;; mindbrook-test.el --- Tests for mindbrook  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;
;;   emacs -Q --batch -L . -L test -l test/mindbrook-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'mindbrook)

(defmacro mindbrook-test--with-dirs (&rest body)
  "Run BODY with fresh temporary scratchpad and template directories."
  (declare (indent 0))
  `(let* ((mindbrook-dir (file-name-as-directory (make-temp-file "mindbrook-" t)))
          (mindbrook-template-dir (file-name-concat mindbrook-dir "templates")))
     (make-directory mindbrook-template-dir)
     (unwind-protect (progn ,@body)
       (delete-directory mindbrook-dir t))))

(defun mindbrook-test--file (dir name content)
  "Create file NAME in DIR holding CONTENT and return its name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

(defun mindbrook-test--kill (buf)
  "Kill BUF, discarding any unsaved edits."
  (when (buffer-live-p buf)
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)))

(ert-deftest mindbrook-test-sanitize-topic ()
  (should (equal (mindbrook--sanitize-topic "  Rust: borrow/checker?  ")
                 "Rust borrow checker"))
  (should (equal (mindbrook--sanitize-topic "Notes v1.2") "Notes v1.2"))
  (should (equal (mindbrook--sanitize-topic "..Rust borrow checker. ") "Rust borrow checker"))
  (should (equal (mindbrook--sanitize-topic "*scratch*") "scratch"))
  (should-not (mindbrook--sanitize-topic " ... "))
  (should-not (mindbrook--sanitize-topic nil)))

(ert-deftest mindbrook-test-unique-file-name ()
  (mindbrook-test--with-dirs
    (should (equal (mindbrook--unique-file-name "2026" "Rust" ".md") "2026 Rust.md"))
    (mindbrook-test--file mindbrook-dir "2026 Rust.md" "")
    (should (equal (mindbrook--unique-file-name "2026" "Rust" ".md") "2026 Rust 2.md"))))

(ert-deftest mindbrook-test-templates ()
  "Only regular files that are not backups are templates."
  (mindbrook-test--with-dirs
    (should-error (mindbrook--templates) :type 'user-error)
    (mindbrook-test--file mindbrook-template-dir "note.org" "")
    (mindbrook-test--file mindbrook-template-dir "note.org~" "")
    (mindbrook-test--file mindbrook-template-dir "#note.org#" "")
    (make-directory (expand-file-name "sub" mindbrook-template-dir))
    (should (equal (mindbrook--templates) '("note.org"))))
  (let ((mindbrook-template-dir "/nonexistent/mindbrook/templates"))
    (should-error (mindbrook--templates) :type 'user-error)))

(ert-deftest mindbrook-test-new ()
  "Topics are inserted literally, and point is left at <START>."
  (mindbrook-test--with-dirs
    (let ((mindbrook-date-format "STAMP")
          buf)
      (mindbrook-test--file mindbrook-template-dir "note.org"
                            "#+title: <TOPIC>\n<topic>\n<START>\n")
      (unwind-protect
          (progn
            (setq buf (mindbrook-new "note.org" "a\\&b: c/d"))
            (with-current-buffer buf
              (should (equal (file-name-nondirectory buffer-file-name)
                             "STAMP a &b c d.org"))
              (should (equal (buffer-string) "#+title: a\\&b: c/d\n<topic>\n\n"))
              (should (= (point) (- (point-max) 1)))
              (should-not (buffer-modified-p))))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-new-never-overwrites ()
  (mindbrook-test--with-dirs
    (let ((mindbrook-date-format "STAMP")
          buf)
      (mindbrook-test--file mindbrook-template-dir "note" "new")
      (mindbrook-test--file mindbrook-dir "STAMP Rust" "old")
      (unwind-protect
          (progn
            (setq buf (mindbrook-new "note" "Rust"))
            (with-current-buffer buf
              (should (equal (file-name-nondirectory buffer-file-name) "STAMP Rust 2"))
              (should (= (point) (point-max))))
            (should (equal (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name "STAMP Rust" mindbrook-dir))
                             (buffer-string))
                           "old")))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-new-creates-dir ()
  (mindbrook-test--with-dirs
    (let ((mindbrook-dir (expand-file-name "new/" mindbrook-dir))
          buf)
      (mindbrook-test--file mindbrook-template-dir "note.txt" "")
      (unwind-protect
          (progn
            (setq buf (mindbrook-new "note.txt" "Rust"))
            (should (file-exists-p (buffer-file-name buf))))
        (mindbrook-test--kill buf)))))

(ert-deftest mindbrook-test-new-refuses-empty-topic ()
  (mindbrook-test--with-dirs
    (mindbrook-test--file mindbrook-template-dir "note.txt" "")
    (should-error (mindbrook-new "note.txt" " ./ ") :type 'user-error)
    (should-not (directory-files mindbrook-dir nil "\\.txt\\'"))))

(provide 'mindbrook-test)

;;; mindbrook-test.el ends here
