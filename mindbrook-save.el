;;; mindbrook-save.el --- Save any buffer as a scratchpad  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mattias Nyrell

;; Author: Mattias Nyrell <mattias@nyrell.se>
;; URL: https://github.com/nyrell/mindbrook
;; Keywords: convenience
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.  It is distributed under the MIT
;; License; see the LICENSE file for the full text.

;;; Commentary:

;; `mindbrook-save-as-scratchpad' saves the current buffer as a
;; scratchpad in `mindbrook-dir', or copies or moves the file it visits
;; there.  The file name is picked from suggestions that start with a
;; time stamp.
;;
;; With `mindbrook-save-ai-topic' set to `ask', one suggestion uses a
;; topic from a gptel summary of the buffer.  gptel is never loaded from
;; here; it must already be loaded and configured.  The user is always
;; asked before any text is sent.

;;; Code:

(require 'subr-x)
(require 'mindbrook)

(defgroup mindbrook-save nil
  "Save any buffer as a scratchpad."
  :prefix "mindbrook-save-"
  :group 'mindbrook)

(defcustom mindbrook-save-ai-topic nil
  "Whether `mindbrook-save-as-scratchpad' may ask gptel for a topic.
When nil, no topic is suggested.  When `ask', the user is asked before
any buffer text is sent.  gptel must already be loaded."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Ask before sending" ask))
  :package-version '(mindbrook . "0.4.0")
  :group 'mindbrook-save)

(defcustom mindbrook-save-ai-context-size 4000
  "Number of characters from the start of the buffer sent for a topic.
If the region is active, the region is sent instead.  A region longer
than this is sent whole only if the user agrees."
  :type 'integer
  :package-version '(mindbrook . "0.4.0")
  :group 'mindbrook-save)

(defcustom mindbrook-save-ai-timeout 30
  "Seconds to wait for gptel to suggest a topic."
  :type 'number
  :package-version '(mindbrook . "0.4.0")
  :group 'mindbrook-save)

;;;; AI topic suggestions

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
;; A `cl-defun' with keyword arguments, so leave its arglist unchecked.
(declare-function gptel-request "ext:gptel-request" t)
(declare-function gptel-abort "ext:gptel-request" (buf))

(defconst mindbrook-save--ai-prompt
  "Reply with a short topic of at most six words for the text below. Reply with the topic only: no quotes, no punctuation, no explanation."
  "System message used to ask gptel for a scratchpad topic.")

(defun mindbrook-save--ai-text ()
  "Return the text to send for a topic, or nil if nothing is to be sent.
That is the active region, or else the buffer, cut to
`mindbrook-save-ai-context-size' characters.  Nothing is sent for blank
text or unless the user agrees.  A region over the limit is sent whole
if the user wants to."
  (let* ((region (use-region-p))
         (all (string-trim
               (buffer-substring-no-properties
                (if region (region-beginning) (point-min))
                (if region (region-end) (point-max)))))
         (limit mindbrook-save-ai-context-size)
         (text (if (> (length all) limit) (substring all 0 limit) all)))
    (when (and (not (string-empty-p text))
               (y-or-n-p (format "Send %d characters of %s to gptel for a topic? "
                                 (length text)
                                 (if region "the region" (buffer-name)))))
      (if (and region
               (> (length all) limit)
               (y-or-n-p (format "The region is %d characters, over the limit of %d.  Send all of it anyway? "
                                 (length all) limit)))
          all
        text))))

(defun mindbrook-save--ai-request (text)
  "Ask gptel for a topic summarizing TEXT and wait for the answer.
Return the first line of the answer, or nil if the request failed or
took longer than `mindbrook-save-ai-timeout' seconds.  An unfinished
request is aborted."
  (let ((done nil)
        (topic nil)
        (backend gptel-backend)
        (model gptel-model)
        ;; A buffer of its own, so `gptel-abort' stops only this request.
        (buf (generate-new-buffer " *mindbrook-save-ai*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local gptel-backend backend)
            (setq-local gptel-model model)
            ;; A gptel buffer may enable tools, and a tool call is not a topic.
            (setq-local gptel-use-tools nil))
          (condition-case err
              (gptel-request text
                             :buffer buf
                             :system mindbrook-save--ai-prompt
                             :stream nil
                             :callback (lambda (response _info)
                                         (cond ((stringp response)
                                                (setq topic response done t))
                                               ((not (consp response)) ;nil or `abort'
                                                (setq done t)))))
            (error (message "Topic request to gptel failed: %s"
                            (error-message-string err))
                   (setq done t)))
          ;; A quit only gives up on the suggestion.
          (condition-case nil
              (with-timeout (mindbrook-save-ai-timeout)
                (while (not done)
                  (accept-process-output nil 0.1)))
            (quit nil)))
      (unless done
        (gptel-abort buf))
      (kill-buffer buf))
    (and topic (car (split-string topic "\n" t "[ \t]+")))))

(defun mindbrook-save--ai-topic ()
  "Return a topic for the current buffer suggested by gptel, or nil.
Nothing is sent unless `mindbrook-save-ai-topic' is non-nil, gptel is
loaded, there is text to send and the user agrees to send it."
  (when mindbrook-save-ai-topic
    ;; Not `fboundp': an autoload would load gptel.  Older gptel versions
    ;; have no separate gptel-request library.
    (if (not (or (featurep 'gptel-request) (featurep 'gptel)))
        (progn (message "gptel is not loaded, so no topic is suggested") nil)
      (let ((text (mindbrook-save--ai-text)))
        (when text
          (message "Asking gptel for a scratchpad topic...")
          (prog1 (mindbrook-save--ai-request text)
            (message nil)))))))

;;;; Saving buffers as scratchpads

(defun mindbrook-save--extension-for-mode ()
  "Return the file name extension that suits the current major mode."
  (cond ((derived-mode-p 'org-mode) "org")
        ((derived-mode-p 'markdown-mode) "md")
        (t "txt")))

(defun mindbrook-save--check-buffer ()
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

(defun mindbrook-save--read-file-name (candidates)
  "Read a scratchpad file name, offering CANDIDATES.
Return the absolute file name in `mindbrook-dir'."
  (let ((name (string-trim
               (completing-read (format-prompt "Scratchpad file name" (car candidates))
                                candidates nil nil nil nil (car candidates)))))
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
keeping its major mode unless that is `fundamental-mode'.  For a buffer
visiting a file, choose whether to copy or move the file to
`mindbrook-dir'; after a copy the copy is visited, after a move the
buffer follows the file.  Unsaved changes must be saved first.

The suggested file names start with the current time in
`mindbrook-date-format'.  One uses a topic suggested by gptel, see
`mindbrook-save-ai-topic'; the other the current file or buffer name.
Any other file name can be typed instead.

Return the absolute name of the new scratchpad file."
  (interactive)
  (mindbrook-save--check-buffer)
  (let* ((file buffer-file-name)
         (action (and file
                      (cadr (read-multiple-choice
                             "Copy or move this file to the scratchpad directory?"
                             '((?c "copy") (?m "move"))))))
         (stamp (format-time-string mindbrook-date-format))
         (ext (if file
                  (file-name-extension file t)
                (concat "." (mindbrook-save--extension-for-mode))))
         (topic (mindbrook--sanitize-topic (mindbrook-save--ai-topic)))
         (current (if file
                      (file-name-base file)
                    (or (mindbrook--sanitize-topic (buffer-name)) "scratchpad")))
         (new (mindbrook-save--read-file-name
               (delete-dups
                (delq nil (list (and topic (mindbrook--unique-file-name stamp topic ext))
                                (mindbrook--unique-file-name stamp current ext)))))))
    (make-directory mindbrook-dir t)
    (pcase action
      ("copy"
       (copy-file file new)
       (find-file new))
      ("move"
       (rename-visited-file new))
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

(provide 'mindbrook-save)

;;; mindbrook-save.el ends here
