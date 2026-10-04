;;; britannica.el --- Read 1911 Encyclopaedia Britannica articles  -*- lexical-binding: t; -*-

;; dictionary-mode is right for definitions and wrong for articles.  A Century or
;; Webster entry is a screenful; an EB1911 article runs to pages, has its own
;; cross-reference apparatus -- "(q.v.)", "see AESTHETICS" -- and wants reading
;; rather than glancing at.  So: its own buffer, soft-wrapped to the window,
;; RET to follow a cross-reference, l to come back, w for the Wikisource page.
;;
;;   M-x britannica            prompt, defaulting to the word at point
;;   M-x britannica-at-point   no prompt
;;
;; Needs a local dictd serving the eb1911 database (see install.sh).

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'url-util)
(require 'thingatpt)

(defconst britannica-version "0.4")

(defgroup britannica nil "1911 Encyclopaedia Britannica." :group 'applications)

(defcustom britannica-dict-program "dict"
  "The dict client." :type 'string :group 'britannica)

(defcustom britannica-server "localhost"
  "Host serving the eb1911 database." :type 'string :group 'britannica)

(defcustom britannica-database "eb1911"
  "dictd database name." :type 'string :group 'britannica)

(defcustom britannica-port nil
  "Port of the dict server, or nil for the client default (2628)."
  :type '(choice (const :tag "default" nil) integer) :group 'britannica)

(defun britannica--args (&rest extra)
  (append (list "-h" britannica-server)
          (when britannica-port (list "-p" (number-to-string britannica-port)))
          (list "-d" britannica-database)
          extra))

(defcustom britannica-wikisource-url
  "https://en.wikisource.org/wiki/1911_Encyclop%%C3%%A6dia_Britannica/%s"
  "URL template for the source page; %s is the percent-encoded article title."
  :type 'string :group 'britannica)

(defvar-local britannica--title nil "Article this buffer shows.")
(defvar-local britannica--history nil "Stack of titles visited, most recent first.")

(defun britannica--fetch (term)
  "Raw dict output for TERM, or nil."
  (with-temp-buffer
    (let ((code (apply #'call-process britannica-dict-program nil t nil
                       (britannica--args "--" term))))
      (and (eq code 0) (> (buffer-size) 0) (buffer-string)))))

(defun britannica--strip (raw title)
  "Drop dict\'s header lines, the two-space indent, and the repeated TITLE."
  (let* ((lines (split-string raw "\n"))
         (start (or (cl-position-if (lambda (l) (string-prefix-p "From " l)) lines) -1))
         (body (nthcdr (1+ start) lines))
         (text (string-trim
                (mapconcat (lambda (l) (if (string-prefix-p "  " l) (substring l 2) l))
                           body "\n"))))
    ;; the entry itself begins with its headword; the buffer already has it
    (if (and title (string-prefix-p (downcase title) (downcase text)))
        (string-trim (substring text (length title)))
      text)))

(defun britannica--parse-matches (out)
  "Headwords from dict -m output.
Multi-word matches are quoted, single words are bare -- so Épernay comes back
unquoted and a quotes-only parser misses exactly the entries that need this."
  (let (res)
    (dolist (line (split-string out "\n" t))
      (when (string-match "\\`[^ \t:]+: *\\(.*\\)\\'" line)
        (let ((rest (match-string 1 line)) (pos 0))
          (while (string-match "\"\\([^\"]+\\)\"\\|\\([^ \t]+\\)" rest pos)
            (push (or (match-string 1 rest) (match-string 2 rest)) res)
            (setq pos (match-end 0))))))
    (nreverse res)))

(defun britannica--matches (term)
  "Headwords containing TERM, via dictd's substring strategy.

EB1911 titles biographies \"Surname, Forename\", so exact match is the
wrong default for someone typing Longinus.

dictd drops non-ASCII characters when it compares, so a term containing
any is retried with them removed: Épernay is found by searching pernay."
  (let* ((try (lambda (strategy q)
                (with-temp-buffer
                  (when (eq 0 (apply #'call-process britannica-dict-program nil t nil
                                     (britannica--args "-m" "-s" strategy "--" q)))
                    (britannica--parse-matches (buffer-string))))))
         (ascii (replace-regexp-in-string "[^[:ascii:]]" "" term))
         (alt (and (not (string= ascii term)) (not (string-empty-p ascii)) ascii)))
    ;; prefix first: it is the binary search, and for "Kant" it offers
    ;; "Kant, Immanuel" where substring offers assorted Kantakouzenoses.
    ;; substring second: a linear scan, so it is the one that still works where
    ;; our index order and dictd's disagree.
    (or (funcall try "prefix" term)
        (funcall try "substring" term)
        (and alt (funcall try "prefix" alt))
        (and alt (funcall try "substring" alt)))))

(defun britannica--resolve (term)
  "TERM itself if it has an article, else a chosen substring match, else nil."
  (if (britannica--fetch term)
      term
    (let ((ms (britannica--matches term)))
      (cond ((null ms) nil)
            ((= 1 (length ms)) (car ms))
            (t (let* ((lc (downcase term))
                      ;; prefer the exact title, then one that begins with what
                      ;; was typed, so Kant does not default to Kantakouzenos
                      (best (or (car (member term ms))
                                (seq-find (lambda (m) (string-prefix-p lc (downcase m))) ms)
                                (car ms))))
                 (completing-read (format "Britannica (%d matches): " (length ms))
                                  ms nil t nil nil best)))))))

(defun britannica--word-at-point ()
  (or (and (use-region-p)
           (string-trim (buffer-substring-no-properties
                         (region-beginning) (region-end))))
      (thing-at-point 'word t)))

(defun britannica--render (title body)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize title 'face '(:weight bold :height 1.3)) "\n")
    (insert (propertize (make-string (max 8 (string-width title)) ?─)
                        'face 'shadow)
            "\n\n")
    (insert body "\n")
    (goto-char (point-min))))

(defun britannica--show (title body &optional push)
  (with-current-buffer (get-buffer-create "*britannica*")
    (let ((old britannica--title))
      (britannica-mode)
      (britannica--render title body)
      (setq britannica--title title)
      (when (and push old)
        (push old britannica--history)))
    (display-buffer (current-buffer))))

;;;###autoload
(defun britannica (term)
  "Show the EB1911 article for TERM."
  (interactive (list (read-string "Britannica: " (britannica--word-at-point))))
  (let* ((term (string-trim (or term "")))
         (title (and (not (string-empty-p term)) (britannica--resolve term)))
         (raw (and title (britannica--fetch title))))
    (cond
     ((string-empty-p term) (message "britannica: nothing to look up"))
     ((null raw) (message "britannica: no article for %s" term))
     (t (britannica--show title (britannica--strip raw title) t)))))

;;;###autoload
(defun britannica-at-point ()
  "Show the EB1911 article for the word at point, without prompting."
  (interactive)
  (let ((w (britannica--word-at-point)))
    (if w (britannica w) (message "britannica: no word at point"))))

(defun britannica-follow ()
  "Follow the cross-reference at point -- 1911's hyperlinks were (q.v.)."
  (interactive)
  (let ((w (britannica--word-at-point)))
    (if (not w)
        (message "britannica: no word at point")
      (let* ((title (britannica--resolve w))
             (raw (and title (britannica--fetch title))))
        (if raw
            (britannica--show title (britannica--strip raw title) t)
          (message "britannica: no article for %s" w))))))

(defun britannica-back ()
  "Return to the previous article."
  (interactive)
  (if (null britannica--history)
      (message "britannica: no further back")
    (let* ((prev (pop britannica--history))
           (hist britannica--history)
           (raw (britannica--fetch prev)))
      (if (not raw)
          (message "britannica: cannot reopen %s" prev)
        (britannica--show prev (britannica--strip raw prev))
        (with-current-buffer "*britannica*"
          (setq britannica--history hist))))))

(defun britannica-wikisource (&optional external)
  "Open this article on Wikisource -- the scans, footnotes and plates."
  (interactive "P")
  (if (not britannica--title)
      (message "britannica: no article")
    (let ((url (format britannica-wikisource-url
                       (url-hexify-string britannica--title))))
      (message "%s" url)
      (funcall (if external #'browse-url #'eww) url))))

(defvar britannica-mode-map (make-sparse-keymap)
  "Keymap for `britannica-mode'.")

;; applied on load, not inside a defvar: see the same note in yomitan.el
(dolist (b '(("q"   quit-window)
             ("RET" britannica-follow)
             ("l"   britannica-back)
             ("w"   britannica-wikisource)
             ("n"   next-line)
             ("p"   previous-line)))
  (keymap-set britannica-mode-map (car b) (cadr b)))

(define-derived-mode britannica-mode special-mode "Britannica"
  "Major mode for reading EB1911 articles."
  (visual-line-mode 1)          ; articles are long; wrap to the window
  (setq-local show-trailing-whitespace nil))

(provide 'britannica)
;;; britannica.el ends here
