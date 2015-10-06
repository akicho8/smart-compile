;;; smart-compile.el --- an interface to `compile'

;; Copyright (C) 1998-2015  by Seiji Zenitani

;; Author: Seiji Zenitani <zenitani@mac.com>
;; Version: 20150520
;; Keywords: tools, unix
;; Created: 1998-12-27
;; Compatibility: Emacs 21 or later
;; URL(en): https://github.com/zenitani/elisp/blob/master/smart-compile.el
;; URL(jp): http://th.nao.ac.jp/MEMBER/zenitani/elisp-j.html#smart-compile

;; Contributors: Sakito Hisakura, Greg Pfell

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; This package provides `smart-compile' function.
;; You can associates a particular file with a particular compile functions,
;; by editing `smart-compile-alist'.
;;
;; To use this package, add these lines to your .emacs file:
;;     (require 'smart-compile)
;;
;; Note that it requires emacs 21 or later.

;;; Code:

(require 's)

(defgroup smart-compile nil
  "An interface to `compile'."
  :group 'processes
  :prefix "smart-compile")

(defcustom smart-compile-alist
  '(
    (emacs-lisp-mode    . (lispxmp))
    (html-mode          . (browse-url-of-buffer))
    (nxhtml-mode        . (browse-url-of-buffer))
    (html-helper-mode   . (browse-url-of-buffer))
    (octave-mode        . (run-octave))
    ("\\.c\\'"          . "gcc -O2 %f -lm -o %n")
    ;;  ("\\.c\\'"          . "gcc -O2 %f -lm -o %n && ./%n")
    ("\\.[Cc]+[Pp]*\\'" . "g++ -O2 %f -lm -o %n")
    ("\\.m\\'"          . "gcc -O2 %f -lobjc -lpthread -o %n")
    ("\\.java\\'"       . "javac %f")
    ("\\.php\\'"        . "php -l %f")
    ("\\.f90\\'"        . "gfortran %f -o %n")
    ("\\.[Ff]\\'"       . "gfortran %f -o %n")
    ("\\.cron\\(tab\\)?\\'" . "crontab %f")
    ("\\.tex\\'"        . (tex-file))
    ("\\.texi\\'"       . "makeinfo %f")
    ("\\.mp\\'"         . "mptopdf %f")
    ("\\.pl\\'"         . "perl %f")
    ("\\.crontab\\'"    . "crontab %f")
    ("\\.coffee\\'"     . "coffee -c %f && coffee -p %f")
    ("\\.ya?ml\\'"      . "ruby -w -r socket -r yaml -r erb -r pathname -r rubygems -e 'YAML.load(ERB.new(ARGF.read).result(binding)).to_yaml.display' %f")
    ("/apache2/.*\\.conf\\'" .  "apachectl configtest; apachectl -S; sudo apachectl restart")
    ("Rakefile"         . "rake")
    ("\\.csv\\'"        . "ruby -r csv -r pp -e 'pp CSV.parse(ARGF.read.gsub(/^#.*$/, \"\"), headers: :first_row, header_converters: :symbol, skip_blanks: true, converters: [:date_time, :date, :numeric]).collect(&:to_h)' %F")
    ;; 優先度が重要なもの
    ;; ruby
    ("/spec/.*_spec\\.rb\\'" . "cd %G && rspec %L")
    ("\\.rb\\'" . "ruby %f")
    )  "Alist of filename patterns vs corresponding format control strings.
Each element looks like (REGEXP . STRING) or (MAJOR-MODE . STRING).
Visiting a file whose name matches REGEXP specifies STRING as the
format control string.  Instead of REGEXP, MAJOR-MODE can also be used.
The compilation command will be generated from STRING.
The following %-sequences will be replaced by:

  %F  absolute pathname            ( /usr/local/bin/netscape.bin )
  %f  file name without directory  ( netscape.bin )
  %n  file name without extension  ( netscape )
  %e  extension of file name       ( bin )

  %o  value of `smart-compile-option-string'  ( \"user-defined\" ).

If the second item of the alist element is an emacs-lisp FUNCTION,
evaluate FUNCTION instead of running a compilation command.
"
       :type '(repeat
               (cons
                (choice
                 (regexp :tag "Filename pattern")
                 (function :tag "Major-mode"))
                (choice
                 (string :tag "Compilation command")
                 (sexp :tag "Lisp expression"))))
       :group 'smart-compile)
(put 'smart-compile-alist 'risky-local-variable t)

(defconst smart-compile-replace-alist
  '(
    ("%F" . (buffer-file-name))                                                      ; /path/to/myapp/app/models/user.rb
    ("%f" . (file-name-nondirectory (buffer-file-name)))                             ; user.rb
    ("%n" . (file-name-sans-extension (file-name-nondirectory (buffer-file-name))))  ; user
    ("%e" . (or (file-name-extension (buffer-file-name)) ""))                        ; rb
    ("%G" . (smart-compile-git-root))                                                ; /path/to/myapp/
    ("%L" . (s-replace (concat (smart-compile-git-root) "/") "" (buffer-file-name))) ; app/models/user.rb
    ("%U" . (user-login-name))
    ("%o" . smart-compile-option-string)
    ))
(put 'smart-compile-replace-alist 'risky-local-variable t)

(defcustom smart-compile-option-string ""
  "The option string that replaces %o.  The default is empty."
  :type 'string
  :group 'smart-compile)

;;;###autoload
(defun smart-compile (&optional arg)
  "An interface to `compile'.
It calls `compile' or other compile function,
which is defined in `smart-compile-alist'."
  (interactive "p")
  (let ((executed? nil))
    (when (not (buffer-file-name))
      (error "cannot get filename."))

    ;; C-u を前置したときだけ再読み込みさせる
    (setq compilation-read-command (not (= arg 1)))

    (when (smart-compile-has-local-compile-command-p)
      (call-interactively 'compile)
      (setq executed? t))

    ;; compile
    (unless executed?
      (let ((alist smart-compile-alist)
            (case-fold-search nil)
            (function nil))
        (while (and alist)
          (if (or (and (symbolp (caar alist)) (eq (caar alist) major-mode))
                  (and (stringp (caar alist)) (string-match (caar alist) (buffer-file-name))))
              (progn
                (setq function (cdar alist))
                (if (stringp function)
                    (progn
                      (set (make-local-variable 'compile-command) (smart-compile-string function))
                      (call-interactively 'compile))
                  (if (listp function)
                      (eval function)))
                (setq alist nil)
                (setq executed? t))
            (setq alist (cdr alist))))))

    ;; If compile-command is not defined and the contents begins with "#!",
    ;; set compile-command to filename.
    (unless executed?
      (unless (smart-compile-has-local-compile-command-p)
        (let ((buffer (buffer-substring 1 (min 3 (point-max)))))
          (when (s-prefix? "#!" buffer)
            (set (make-local-variable 'compile-command) (buffer-file-name))))))

    ;; compile
    (when (not executed?)
      (call-interactively 'compile))))

(defun smart-compile-has-local-compile-command-p ()
  (and (local-variable-p 'compile-command)
       compile-command))

(defun smart-compile-string (format-string)
  "Document forthcoming..."
  (when (buffer-file-name)
    (let ((rlist smart-compile-replace-alist)
          (case-fold-search nil))
      (while rlist
        (while (string-match (caar rlist) format-string)
          (setq format-string (replace-match (eval (cdar rlist)) t nil format-string)))
        (setq rlist (cdr rlist)))))
  format-string)

(defun smart-compile-git-root ()
  (expand-file-name (locate-dominating-file default-directory ".git")))

(provide 'smart-compile)

;;; smart-compile.el ends here
