;;; init.el --- just enough emacs for a scratchpad  -*- lexical-binding: t -*-
;;
;; Runs as a daemon behind `scratch' (shell/aliases.sh), in the terminal. No packages.

;; Customize writes here instead of appending to this file.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

(setq-default
 inhibit-startup-screen t
 initial-scratch-message ""
 initial-major-mode 'text-mode
 column-number-mode t
 kill-ring-max 128
 scroll-conservatively most-positive-fixnum
 show-paren-delay 0
 ;; no backup~ files or #autosave# litter next to whatever gets opened
 make-backup-files nil
 auto-save-default nil)

;; Kills go to the system clipboard over OSC 52 (Ghostty, and tmux passes it through).
(setq xterm-extra-capabilities '(getSelection setSelection modifyOtherKeys))

(global-hl-line-mode)
(xterm-mouse-mode)
(add-hook 'before-save-hook #'delete-trailing-whitespace)

;; *scratch* persists: it's saved to a file whenever emacs sits idle and on exit, and reloaded
;; when the daemon starts, so a reboot or a crash loses at most the last couple of seconds.
(defvar my/scratch-file (expand-file-name "scratch.txt" user-emacs-directory))

(defun my/scratch-save ()
  (when-let* ((buf (get-buffer "*scratch*")))
    (with-current-buffer buf
      (when (buffer-modified-p)
        (write-region nil nil my/scratch-file nil 'silent)
        (set-buffer-modified-p nil)))))

(defun my/scratch-restore ()
  (with-current-buffer (get-buffer-create "*scratch*")
    (when (file-exists-p my/scratch-file)
      (erase-buffer)
      (insert-file-contents my/scratch-file))
    (set-buffer-modified-p nil)))

(add-hook 'emacs-startup-hook #'my/scratch-restore)
(add-hook 'kill-emacs-hook #'my/scratch-save)
(run-with-idle-timer 2 t #'my/scratch-save)
;; C-x k on *scratch* just buries it, so the notes can't be thrown away by accident.
(add-hook 'kill-buffer-query-functions
          (lambda ()
            (if (equal (buffer-name) "*scratch*") (progn (bury-buffer) nil) t)))

(defun my/smarter-move-beginning-of-line (arg)
  "Toggle point between the first non-whitespace character and the start of the line.
With ARG not nil or 1, move forward ARG - 1 lines first."
  (interactive "^p")
  (setq arg (or arg 1))
  (when (/= arg 1)
    (let ((line-move-visual nil))
      (forward-line (1- arg))))
  (let ((orig-point (point)))
    (back-to-indentation)
    (when (= orig-point (point))
      (move-beginning-of-line 1))))

(global-set-key (kbd "C-a") #'my/smarter-move-beginning-of-line)
