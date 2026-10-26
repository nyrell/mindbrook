;;; mindbrook.el --- Persistent scratchpads from templates  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mattias Nyrell

;; Author: Mattias Nyrell <mattias@nyrell.se>
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/nyrell/mindbrook
;; Keywords: convenience
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.  It is distributed under the MIT
;; License; see the LICENSE file for the full text.

;;; Commentary:

;; Create persistent scratchpads from templates with `mindbrook-new'.
;; Scratchpads are plain files in `mindbrook-dir', named from a time
;; stamp and a topic.
;;
;; The optional mindbrook-save.el adds `mindbrook-save-as-scratchpad',
;; which saves any buffer as a scratchpad.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup mindbrook nil
  "Easily create persistent scratchpads from templates.
A simpler, more lightweight alternative to the Mindstream package."
  :link '(url-link "https://github.com/nyrell/mindbrook")
  :prefix "mindbrook-"
  :group 'convenience)

(defcustom mindbrook-dir
  "~/Documents/mindbrook"
  "The directory where the scratchpads are stored."
  :type 'directory
  :group 'mindbrook)

(defcustom mindbrook-template-dir
  "~/Documents/mindbrook/templates"
  "The directory where the templates for new scratchpads are stored."
  :type 'directory
  :group 'mindbrook)

(defcustom mindbrook-date-format
  "%Y-%m-%d %H%M%S"
  "The date format to use for the time stamp in the file name of a new scratchpad."
  :type 'string
  :group 'mindbrook)

(defun mindbrook--sanitize-topic (topic)
  "Return TOPIC cleaned up for use in a file name, or nil if nothing is left.
Dots are kept, except at the start and end."
  (let ((clean (string-trim
                (replace-regexp-in-string
                 "[[:space:]]+" " "
                 (replace-regexp-in-string "[\\/:*?\"<>|#]+" " "
                                           (or topic "")))
                "[[:space:].]+" "[[:space:].]+")))
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

(defun mindbrook--templates ()
  "Return the names of the template files in `mindbrook-template-dir'."
  (unless (file-directory-p mindbrook-template-dir)
    (user-error "No template directory %s" mindbrook-template-dir))
  (or (seq-filter (lambda (name)
                    (and (file-regular-p (expand-file-name name mindbrook-template-dir))
                         (not (backup-file-name-p name))
                         (not (auto-save-file-name-p name))))
                  (directory-files mindbrook-template-dir nil
                                   directory-files-no-dot-files-regexp))
      (user-error "No templates in %s" mindbrook-template-dir)))

;;;###autoload
(defun mindbrook-new (template topic)
  "Create a new scratchpad from TEMPLATE about TOPIC.

TEMPLATE is the name of a file in `mindbrook-template-dir'.  The
scratchpad is named from the current time and TOPIC, with the extension
of TEMPLATE.  Each <TOPIC> in the template is replaced by TOPIC, and
point is left where <START> was, or else at the end.

Return the buffer of the new scratchpad."
  (interactive
   (list (completing-read "Template: " (mindbrook--templates) nil t)
         (read-string "Topic: ")))
  (let* ((name (or (mindbrook--sanitize-topic topic)
                   (user-error "The topic must not be empty")))
         (file (expand-file-name
                (mindbrook--unique-file-name (format-time-string mindbrook-date-format)
                                             name
                                             (file-name-extension template t))
                mindbrook-dir))
         buf)
    (make-directory mindbrook-dir t)
    (setq buf (find-file-noselect file))
    (with-current-buffer buf
      (insert-file-contents (expand-file-name template mindbrook-template-dir))
      (replace-string-in-region "<TOPIC>" topic (point-min))
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (if (search-forward "<START>" nil t)
            (replace-match "" t t)
          (goto-char (point-max))))
      (save-buffer))
    (pop-to-buffer-same-window buf)
    buf))

(provide 'mindbrook)

;;; mindbrook.el ends here
