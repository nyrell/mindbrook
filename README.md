# Mindbrook

Mindbrook is a lightweight application to easily create persistent scratchpads from templates. Created as a simpler, more light weight, alternative to the [Mindstream package](https://github.com/countvajhula/mindstream).

Scratchpads are stored as simple text files, created from a set of templates that you create yourself.

# Installation

Download and place on your load path and `require` in your Emacs configuration. 

For example:

Download to: ~/.emacs.d/other-packages

```elisp
;; Add non-elpa packages to load path
(let ((default-directory (file-name-concat user-emacs-directory "other-packages/")))
  (when (file-exists-p default-directory)
    (normal-top-level-add-subdirs-to-load-path)))

(require 'mindbrook)
```

# Configuration
Customize `mindbrook-dir` to specify where new scratchpads are created, default is `~/Documents/mindbrook`.

Customize `mindbrook-template-dir` to specify where mindbrook looks for templates, default is `~/Documents/mindbrook/templates`.

Customize `mindbrook-date-format` to specify the format of the timestamp prefix used for all scratchpads, default is "YYYY-MM-DD HH:MM:SS".

The function `mindbrook-new` is used to create a new scratchpad, so you might want to create a key binding for it.

You can also set these variables directly in your Emacs configuration, for example:

```elisp
(setq mindbrook-dir "~/Documents/0. Scratchpads")
(setq mindbrook-template-dir (file-name-concat mindbrook-dir "templates"))
(setq mindbrook-date-format "%Y-%m-%d %H%M%S")

(global-set-key (kbd "C-c s") 'mindbrook-new)
```

## gptel-agent scratchpads

If [gptel-agent](https://github.com/karthink/gptel-agent) is installed, `mindbrook-new-gptel-agent` starts an agent session whose buffer is a scratchpad in `mindbrook-dir`, named `<timestamp> gptel-agent.md` (`.org` or `.txt` if gptel uses `org-mode` or `text-mode`). With a prefix argument it asks for the project directory, like `gptel-agent`.

The first time you save the conversation, gptel suggests a topic. You can edit it in the minibuffer, and the file is then renamed in place to `<timestamp> <topic>.md`. Only the start of the conversation is sent (`mindbrook-gptel-topic-context-size` characters), and `C-g` while waiting skips the suggestion without stopping the save. Leave the topic empty to keep the placeholder and be asked again on the next save. `mindbrook-gptel-topic-timeout` sets how long to wait for the suggestion.

## Example: BASB/PARA setup

Personally I use these scratchpads as part of a [BASB/PARA](https://www.buildingasecondbrain.com/para) setup, where I have the following directory structure:

* ~/org/0. Scratchpads/
* ~/org/1. Projects/
* ~/org/2. Areas/
* ~/org/3. Resources/
* ~/org/4. Archive/

Scratchpads are created quickly based from a number of templates, and then either stays in "0. Scratchpads" or is migrated to any of the other PARA directories as needed.

To make it easy to work with I have defined the following transient:


