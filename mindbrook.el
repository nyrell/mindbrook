;;; mindbrook.el --- Persistent scratchpads from templates  -*- lexical-binding: t; -*-

;; Author: Mattias Nyrell <mattias@nyrell.se>
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/nyrell/mindbrook
;; Keywords: convenience
;; SPDX-License-Identifier: MIT

;; Copyright (c) 2026 Mattias Nyrell

;; This file is not part of GNU Emacs.  It is distributed under the MIT
;; License; see the LICENSE file for the full text.

;;; Commentary:

;; Create persistent scratchpads from templates with `mindbrook-new', or
;; save any buffer as a scratchpad with `mindbrook-save-as-scratchpad'.
;; mindbrook-ai.el can suggest a topic for the file name using gptel.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup mindbrook nil
  "Easily create persistent scratchpads from templates.
A simpler, more lightweight alternative to the Mindstream package."
  ;; :link ""
  :group 'convenience)

(defcustom mindbrook-dir
  "~/Documents/mindbrook"
  "The directory where the scratchpads are stored."
  :type 'string
  :group 'mindbrook)

(defcustom mindbrook-template-dir
  "~/Documents/mindbrook/templates"
  "The directory where the templates for new scratchpads are stored."
  :type 'string
  :group 'mindbrook)

(defcustom mindbrook-date-format
  "%Y-%m-%d %H%M%S"
  "The date format to use for the time stamp in the file name of a new scratchpad."
  :type 'string
  :group 'mindbrook)

(defcustom mindbrook-topic-function nil
  "Function that suggests a topic for `mindbrook-save-as-scratchpad'.
It is called with no arguments in the buffer being saved and returns a
topic string or nil.  When nil, no topic is suggested.  See
`mindbrook-ai-topic' in mindbrook-ai.el for one that asks gptel."
  :type '(choice (const :tag "None" nil) function)
  :group 'mindbrook)

;; (setq mindbrook-dir (file-name-concat my-org-dir "org-scratchpads"))
;; (setq mindbrook-template-dir (file-name-concat my-org-dir "org-scratchpads" "templates"))
;; (setq mindbrook-date-format "%Y-%m-%d %H%M%S")

(defun mindbrook-new ()
  "Create a new scratchpad file from a template with a specified topic name."
  (interactive)
  (let* ((template-file (completing-read "Select template: "
                                         (directory-files mindbrook-template-dir nil nil)))
         (template-file-path (expand-file-name template-file mindbrook-template-dir))
         (file-ext (file-name-extension template-file))
         (topic-name (read-string "Enter topic name for new scratchpad: "))
         (timestamp (format-time-string mindbrook-date-format))
         (new-file-name (expand-file-name (format "%s %s.%s" timestamp topic-name file-ext) mindbrook-dir)))
    (with-current-buffer (find-file-noselect new-file-name)
      (insert-file-contents template-file-path)

      (goto-char (point-min))
      (while (search-forward "<TOPIC>" nil t)
        (replace-match topic-name t))

      (goto-char (point-min))
      (if (search-forward "<START>" nil t)
          (replace-match "")
        (goto-char (point-max)))

      (save-buffer))

    (find-file new-file-name)))

;;;; Saving buffers as scratchpads

(defun mindbrook--sanitize-topic (topic)
  "Return TOPIC cleaned up for use in a file name, or nil if nothing is left."
  (let ((clean (string-trim
                (replace-regexp-in-string
                 "[[:space:]]+" " "
                 (replace-regexp-in-string "[\\/:*?\"<>|.#]+" " "
                                           (or topic ""))))))
    (unless (string-empty-p clean) clean)))

(defun mindbrook--unique-file-name (stamp topic ext)
  "Return the name \"STAMP TOPIC.EXT\" of a file not yet in `mindbrook-dir'.
EXT includes its period.  A counter is added if the name is taken."
  (let* ((base (format "%s %s" stamp topic))
         (name (concat base ext))
         (n 1))
    (while (file-exists-p (expand-file-name name mindbrook-dir))
      (setq n (1+ n)
            name (format "%s %d%s" base n ext)))
    name))

(defun mindbrook--extension-for-mode ()
  "Return the file name extension that suits the current major mode."
  (cond ((derived-mode-p 'org-mode) "org")
        ((derived-mode-p 'markdown-mode) "md")
        (t "txt")))

(defun mindbrook--check-buffer ()
  "Signal a `user-error' unless the current buffer can be a scratchpad."
  (when (or (eq (get major-mode 'mode-class) 'special)
            (derived-mode-p 'special-mode 'dired-mode 'image-mode))
    (user-error "A %s buffer cannot be saved as a scratchpad" mode-name))
  (when (and buffer-file-name
             (file-in-directory-p buffer-file-name mindbrook-dir))
    (user-error "This file is already in %s" mindbrook-dir))
  (when (and buffer-file-name (buffer-modified-p))
    (if (y-or-n-p (format "Save %s first? " (buffer-name)))
        (save-buffer)
      (user-error "The buffer must be saved before it can be copied or moved"))))

(defun mindbrook--read-file-name (candidates)
  "Read a scratchpad file name, offering CANDIDATES.
Return the absolute file name in `mindbrook-dir'."
  (let ((name (string-trim
               (completing-read "Scratchpad file name: " candidates
                                nil nil nil nil (car candidates)))))
    (when (or (string-empty-p name)
              (not (equal name (file-name-nondirectory name))))
      (user-error "Not a valid file name: %S" name))
    (let ((file (expand-file-name name mindbrook-dir)))
      (when (file-exists-p file)
        (user-error "%s already exists" file))
      file)))

;;;###autoload
(defun mindbrook-save-as-scratchpad ()
  "Save the current buffer as a scratchpad in `mindbrook-dir'.

A buffer that is not visiting a file is saved to the new scratchpad,
keeping its major mode unless that is `fundamental-mode'.
For a buffer visiting a file, choose whether to copy or move the file
to `mindbrook-dir'; after a copy the copy is visited, after a move the
buffer follows the file.  Unsaved changes must be saved first.

The suggested file names start with the current time in
`mindbrook-date-format'.  One uses the topic suggested by
`mindbrook-topic-function', if set; the other the current file or buffer
name.  Any
other file name can be typed instead."
  (interactive)
  (mindbrook--check-buffer)
  (let* ((file buffer-file-name)
         (action (and file
                      (cadr (read-multiple-choice
                             "Copy or move this file to the scratchpad directory? "
                             '((?c "copy") (?m "move"))))))
         (stamp (format-time-string mindbrook-date-format))
         (ext (if file
                  (file-name-extension file t)
                (concat "." (mindbrook--extension-for-mode))))
         (topic (and mindbrook-topic-function
                     (mindbrook--sanitize-topic (funcall mindbrook-topic-function))))
         (current (if file
                      (file-name-base file)
                    (or (mindbrook--sanitize-topic (buffer-name)) "scratchpad")))
         (new (mindbrook--read-file-name
               (delete-dups
                (delq nil (list (and topic (mindbrook--unique-file-name stamp topic ext))
                                (mindbrook--unique-file-name stamp current ext)))))))
    (make-directory mindbrook-dir t)
    (pcase action
      ("copy"
       (copy-file file new)
       (find-file new))
      ("move"
       (rename-file file new)
       (set-visited-file-name new nil t))
      (_
       (let ((name (buffer-name))
             ;; Keep the major mode, and with it any buffer-local state,
             ;; unless there is none to keep.
             (change-major-mode-with-file-name (eq major-mode 'fundamental-mode)))
         (condition-case err
             (progn
               (set-visited-file-name new)
               (save-buffer))
           (t
            (set-visited-file-name nil)
            (rename-buffer name)
            (signal (car err) (cdr err)))))))
    new))

(provide 'mindbrook)

;;; mindbrook.el ends here
