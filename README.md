# Mindbrook

Mindbrook is a lightweight application to easily create persistent scratchpads from templates. Created as a simpler, more light weight, alternative to the [Mindstream package](https://github.com/countvajhula/mindstream).

Scratchpads are stored as simple text files, created from a set of templates that you create yourself, or saved from any buffer.

# Installation

Mindbrook requires Emacs 29.1 or later.

Install it with `package-vc-install`:

```elisp
(package-vc-install "https://github.com/nyrell/mindbrook")
```

Or download it, place it on your load path and `require` it in your Emacs configuration. For example, after downloading to `~/.emacs.d/other-packages`:

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

Customize `mindbrook-date-format` to specify the format of the timestamp prefix used for all scratchpads, default is `"%Y-%m-%d %H%M%S"` (for example `2026-10-25 214500`).

The command `mindbrook-new` creates a new scratchpad from a template, so you might want to create a key binding for it. Each `<TOPIC>` in the template is replaced by the topic you enter, and the cursor is placed where `<START>` is, or else at the end.

You can also set these options directly in your Emacs configuration, for example:

```elisp
(setopt mindbrook-dir "~/Documents/0. Scratchpads")
(setopt mindbrook-template-dir (file-name-concat mindbrook-dir "templates"))
(setopt mindbrook-date-format "%Y-%m-%d %H%M%S")

(keymap-global-set "C-c s" #'mindbrook-new)
```

## Saving any buffer as a scratchpad

The optional `mindbrook-save.el` adds `mindbrook-save-as-scratchpad`, which saves the current buffer as a scratchpad in `mindbrook-dir`. You pick the file name in the minibuffer from suggestions that start with the current timestamp, or type your own, including the extension.

```elisp
(require 'mindbrook-save)
(keymap-global-set "C-c S" #'mindbrook-save-as-scratchpad)
```

* A buffer that is not visiting a file is saved to the new scratchpad. The suggested extension follows the major mode (`.org`, `.md` or `.txt`). The buffer keeps its major mode, unless it is in `fundamental-mode`.
* For a buffer visiting a file you choose to **copy** or **move** the file. After a copy you are switched to the copy; after a move the buffer follows the file. A buffer with unsaved changes must be saved first. One suggestion is the current file name prefixed with the timestamp.
* Files already in `mindbrook-dir`, and buffers such as Dired or help buffers, are refused.

### AI topic suggestions

If [gptel](https://github.com/karthink/gptel) is loaded, one of the suggested names uses a topic from a gptel summary of the buffer. Mindbrook never loads gptel itself: it must already be loaded and configured, or no topic is suggested. If gptel fails or gives an answer that is not a short topic, you are told why, and only the other name is suggested.

`mindbrook-save-ai-topic` controls the feature:

* `ask` (the default): you are asked before anything is sent.
* `t`: the text is sent without asking. Think twice before choosing this, since the contents of any buffer you save are then sent to the gptel backend, which may be an outside service. It is meant for a backend you trust, such as a local model.
* `nil`: no topic is suggested.

The start of the buffer is sent, or only the region if it is active; if the region is longer than the limit, you are asked whether to send all of it or only its start. Nothing is sent for a blank buffer.

* `mindbrook-save-ai-backend`: the name of the gptel backend to use, such as `"Ollama"`. The default (`nil`) uses the current gptel backend.
* `mindbrook-save-ai-model`: the model to use, such as `llama3.2`. The default (`nil`) uses the current gptel model, or the first model of `mindbrook-save-ai-backend` if that is set.
* `mindbrook-save-ai-context-size`: the number of characters sent, default 4000.
* `mindbrook-save-ai-timeout`: seconds to wait for the suggestion, default 10. `C-g` while waiting skips it.

For example, to use a local model without being asked:

```elisp
(setopt mindbrook-save-ai-backend "Ollama"
        mindbrook-save-ai-model 'llama3.2
        mindbrook-save-ai-topic t)
```

## Example: BASB/PARA setup

Personally I use these scratchpads as part of a [BASB/PARA](https://www.buildingasecondbrain.com/para) setup, where I have the following directory structure:

* ~/org/0. Scratchpads/
* ~/org/1. Projects/
* ~/org/2. Areas/
* ~/org/3. Resources/
* ~/org/4. Archive/

Scratchpads are created quickly based from a number of templates, and then either stays in "0. Scratchpads" or is migrated to any of the other PARA directories as needed.
