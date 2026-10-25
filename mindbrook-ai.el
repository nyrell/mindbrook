;;; mindbrook-ai.el --- AI suggested scratchpad topics  -*- lexical-binding: t; -*-

;; Author: Mattias Nyrell <mattias@nyrell.se>
;; URL: https://github.com/nyrell/mindbrook
;; Keywords: convenience
;; SPDX-License-Identifier: MIT

;; Copyright (c) 2026 Mattias Nyrell

;; This file is not part of GNU Emacs.  It is distributed under the MIT
;; License; see the LICENSE file for the full text.

;;; Commentary:

;; Let `mindbrook-save-as-scratchpad' suggest a file name topic from a
;; gptel summary of the buffer:
;;
;;   (require 'mindbrook-ai)
;;   (setq mindbrook-topic-function #'mindbrook-ai-topic)
;;
;; gptel itself is never loaded from here; it must already be loaded and
;; configured.  The user is always asked before any text is sent.

;;; Code:

(require 'subr-x)
(require 'mindbrook)

(defcustom mindbrook-ai-timeout 30
  "Seconds to wait for gptel to suggest a topic."
  :type 'number
  :group 'mindbrook)

(defcustom mindbrook-ai-context-size 4000
  "Number of characters from the start of the buffer sent for a topic.
If the region is active, the region is sent instead.  A region longer
than this is sent whole only if the user agrees."
  :type 'integer
  :group 'mindbrook)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
;; A `cl-defun' with keyword arguments, so leave its arglist unchecked.
(declare-function gptel-request "ext:gptel-request" t)
(declare-function gptel-abort "ext:gptel-request" (buf))

(defconst mindbrook-ai--prompt
  "Reply with a short topic of at most six words for the text below. Reply with the topic only: no quotes, no punctuation, no explanation."
  "System message used to ask gptel for a scratchpad topic.")

(defun mindbrook-ai--text ()
  "Return the text to send for a topic, or nil if nothing is to be sent.
That is the active region, or else the buffer, cut to
`mindbrook-ai-context-size' characters.  Nothing is sent for blank text
or unless the user agrees.  A region over the limit is sent whole if
the user wants to."
  (let* ((region (use-region-p))
         (all (string-trim
               (buffer-substring-no-properties
                (if region (region-beginning) (point-min))
                (if region (region-end) (point-max)))))
         (limit mindbrook-ai-context-size)
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

(defun mindbrook-ai--request (text)
  "Ask gptel for a topic summarizing TEXT and wait for the answer.
Return the first line of the answer, or nil if the request failed or
took longer than `mindbrook-ai-timeout' seconds.  An unfinished request
is aborted."
  (let ((done nil)
        (topic nil)
        (backend gptel-backend)
        (model gptel-model)
        ;; A buffer of its own, so `gptel-abort' stops only this request.
        (buf (generate-new-buffer " *mindbrook-ai*")))
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
                :system mindbrook-ai--prompt
                :stream nil
                :callback (lambda (response _info)
                            (cond ((stringp response)
                                   (setq topic response done t))
                                  ((not (consp response)) ;nil or `abort'
                                   (setq done t)))))
            (error (message "gptel request failed: %s" (error-message-string err))
                   (setq done t)))
          ;; A quit only gives up on the suggestion.
          (condition-case nil
              (with-timeout (mindbrook-ai-timeout)
                (while (not done)
                  (accept-process-output nil 0.1)))
            (quit nil)))
      (unless done
        (gptel-abort buf))
      (kill-buffer buf))
    (and topic (car (split-string topic "\n" t "[ \t]+")))))

;;;###autoload
(defun mindbrook-ai-topic ()
  "Return a topic for the current buffer suggested by gptel, or nil.
Meant for `mindbrook-topic-function'.  Nothing is sent unless gptel is
loaded, there is text to send and the user agrees to send it."
  (if (not (fboundp 'gptel-request))
      (progn (message "gptel is not loaded, so no topic is suggested") nil)
    (let ((text (mindbrook-ai--text)))
      (when text
        (message "Asking gptel for a scratchpad topic...")
        (prog1 (mindbrook-ai--request text)
          (message nil))))))

(provide 'mindbrook-ai)

;;; mindbrook-ai.el ends here
