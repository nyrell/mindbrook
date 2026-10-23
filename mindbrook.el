;;; mindbrook.el --- Persistent scratchpads from templates  -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Create persistent scratchpads from templates.  `mindbrook-new-gptel-agent'
;; starts a `gptel-agent' session stored as a scratchpad under
;; `mindbrook-dir', named from an AI summary of the conversation on the
;; first save.

;;; Code:

(require 'subr-x)

(defgroup mindbrook nil
  "A lightweight application to easily create persistent scratchpads from templates. Created as a simpler, more light weight, alternative to the Mindstream package."
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

(defcustom mindbrook-gptel-topic-timeout 30
  "Seconds to wait for gptel to suggest a topic when first saving."
  :type 'number
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
         (new-file-name (expand-file-name (format "%s %s.%s" timestamp topic-name file-ext) mindbrook-dir))
         )
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

;;;; gptel-agent scratchpads

(defvar gptel-mode)
(defvar gptel-use-tools)
(defvar gptel-prompt-prefix-alist)
(declare-function gptel-agent "ext:gptel-agent" (&optional project-dir agent-preset))
(declare-function gptel-request "ext:gptel-request" (&optional prompt &rest args))

(defconst mindbrook--gptel-placeholder "gptel-agent"
  "Topic used in the file name until the conversation has been named.")

(defconst mindbrook--gptel-topic-prompt
  "Reply with a short topic of at most six words for the conversation below. Reply with the topic only: no quotes, no punctuation, no explanation."
  "System message used to ask gptel for a scratchpad topic.")

(defun mindbrook--gptel-conversation ()
  "Return the conversation text of the current buffer.
The file-local variables block that gptel appends on save is left out."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-max))
      (let ((end (if (re-search-backward "^.*Local Variables:" nil t)
                     (line-beginning-position)
                   (point-max))))
        (string-trim (buffer-substring-no-properties (point-min) end))))))

(defun mindbrook--gptel-has-conversation-p (text)
  "Return non-nil if TEXT holds more than empty gptel prompt prefixes."
  (let ((prefixes (mapcar #'string-trim (mapcar #'cdr (bound-and-true-p gptel-prompt-prefix-alist)))))
    (not (string-empty-p
          (string-trim
           (replace-regexp-in-string
            (regexp-opt (seq-remove #'string-empty-p prefixes)) "" text))))))

(defun mindbrook--sanitize-topic (topic)
  "Return TOPIC cleaned up for use in a file name, or nil if nothing is left."
  (let ((clean (string-trim
                (replace-regexp-in-string
                 "[[:space:]]+" " "
                 (replace-regexp-in-string "[\\\\/:*?\"<>|.#]+" " "
                                           (or topic ""))))))
    (unless (string-empty-p clean) clean)))

(defun mindbrook--gptel-request-topic (text)
  "Ask gptel for a topic summarizing TEXT and wait for the answer.
Return the topic string, or nil if the request failed or took longer
than `mindbrook-gptel-topic-timeout' seconds."
  (let ((done nil)
        (topic nil))
    ;; The agent preset enables tools; a topic request must not use them.
    (let ((gptel-use-tools nil))
      (gptel-request text
        :system mindbrook--gptel-topic-prompt
        :stream nil
        :transforms nil
        :callback (lambda (response _info)
                    (cond ((stringp response)
                           (setq topic response done t))
                          ((not (consp response)) ;nil or `abort'
                           (setq done t))))))
    (with-timeout (mindbrook-gptel-topic-timeout)
      (while (not done)
        (accept-process-output nil 0.1)))
    (and topic
         (mindbrook--sanitize-topic
          (car (split-string topic "\n" t "[ \t]+"))))))

(defun mindbrook--gptel-topic-file-name (topic)
  "Return the visited file name with the placeholder replaced by TOPIC.
A counter is added if a file with that name already exists."
  (let* ((dir (file-name-directory buffer-file-name))
         (ext (file-name-extension buffer-file-name t))
         (base (concat (string-remove-suffix
                        mindbrook--gptel-placeholder
                        (file-name-base buffer-file-name))
                       topic))
         (file (expand-file-name (concat base ext) dir))
         (n 1))
    (while (file-exists-p file)
      (setq n (1+ n)
            file (expand-file-name (format "%s %d%s" base n ext) dir)))
    file))

(defun mindbrook--gptel-placeholder-p ()
  "Return non-nil if the visited file still has the placeholder topic."
  (and buffer-file-name
       (string-suffix-p (concat " " mindbrook--gptel-placeholder)
                        (file-name-base buffer-file-name))))

(defun mindbrook--gptel-name-on-save ()
  "Name the scratchpad from an AI summary before it is first saved.

Runs from `before-save-hook' in buffers made by
`mindbrook-new-gptel-agent'.  While the file name still has the
placeholder topic and the buffer holds a conversation, gptel is asked
for a topic, the user may edit it, and the visited file is renamed in
place.  An empty answer keeps the placeholder until the next save."
  (if (not (mindbrook--gptel-placeholder-p))
      (remove-hook 'before-save-hook #'mindbrook--gptel-name-on-save t)
    (let ((text (mindbrook--gptel-conversation)))
      (when (mindbrook--gptel-has-conversation-p text)
        (message "mindbrook: asking gptel for a topic...")
        (let* ((suggestion (mindbrook--gptel-request-topic text))
               (topic (mindbrook--sanitize-topic
                       (read-string "Scratchpad topic: " suggestion))))
          (message nil)
          (when topic
            (rename-visited-file (mindbrook--gptel-topic-file-name topic))
            (remove-hook 'before-save-hook #'mindbrook--gptel-name-on-save t)))))))

;;;###autoload
(defun mindbrook-new-gptel-agent ()
  "Start a `gptel-agent' session stored as a scratchpad in `mindbrook-dir'.

The file is named like other scratchpads, with \"gptel-agent\" as a
placeholder topic.  On the first save of a conversation gptel suggests
a topic, and the file is renamed to use it.  With a prefix argument,
ask for the project directory, as `gptel-agent' does."
  (interactive)
  (unless (fboundp 'gptel-agent)
    (user-error "mindbrook: the gptel-agent package is not installed"))
  (let* ((file (expand-file-name
                (format "%s %s.md" (format-time-string mindbrook-date-format)
                        mindbrook--gptel-placeholder)
                mindbrook-dir))
         (before (buffer-list))
         buf)
    (make-directory mindbrook-dir t)
    ;; `gptel-agent' does not return its buffer, so find the new one.
    (call-interactively #'gptel-agent)
    (setq buf (seq-find (lambda (b)
                          (and (not (memq b before))
                               (buffer-local-value 'gptel-mode b)))
                        (buffer-list)))
    (unless buf
      (error "mindbrook: could not find the new gptel-agent buffer"))
    (with-current-buffer buf
      (set-visited-file-name file t t)
      (add-hook 'before-save-hook #'mindbrook--gptel-name-on-save -50 t))
    (pop-to-buffer buf)
    buf))

(provide 'mindbrook)

;;; mindbrook.el ends here
