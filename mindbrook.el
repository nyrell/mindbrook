;;; ...  -*- lexical-binding: t -*-

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

(provide 'mindbrook)
