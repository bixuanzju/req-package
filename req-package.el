;;; req-package.el --- A use-package wrapper for package runtime dependencies management

;; Copyright (C) 2013-2014 Edward Knyshov

;; Author: Edward Knyshov <edvorg@gmail.com>
;; Created: 25 Dec 2013
;; Version: 0.5
;; Package-Requires: ((use-package "1.0") (dash "2.7.0") (log4e "0.2.0"))
;; Keywords: dotemacs startup speed config package
;; X-URL: https://github.com/edvorg/req-package

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Description

;; req-package is a macro wrapper on top of use-package.
;; It's goal is to simplify package dependencies management,
;; when using use-package for your .emacs.

;; Usage

;; 1) Load req-package:

;;    (require 'req-package)

;; 2) Define required packages with dependencies using :require like this:

;;    (req-package dired) ;; you can omit this empty requirement because of dired-single

;;    (req-package dired-single
;;      :require dired
;;      :config (...))

;;    (req-package lua-mode
;;      :config (...))

;;    (req-package flymake)

;;    (req-package flymake-lua
;;      :require (flymake lua-mode)
;;      :config (...))

;; 3) To start loading packages in right order:

;;    (req-package-finish)

;; Migrate from use-package

;;    Just replace all (use-package ...) with (req-package [:require DEPS] ...)
;;    and add (req-package-finish) at the end of your configuration file.

;; Note

;;    All use-package parameters are supported, see use-package manual for additional info.

;;    However there is now need of :ensure keyword usage. req-package will add it automatically if needed.

;;    Also there is a req-package-force function which simulates plain old use-package behavior

;;    More complex req-package usage example can be found at http://github.com/edvorg/emacs-configs.

;; Changelog:

;;    v0.5:
;;       Major system refactoring.
;;       Fixed bugs with defered loading.
;;       Significant performance optimization.
;;       max-specpdl-size, max-lisp-eval-depth issues completely solved.
;;       Flexible :require keyword parsing.
;;    v0.4.2:
;;       Bug fixes.
;;    v0.4.1:
;;       Various tweaks and bug fixes.
;;    v0.4-all-cycles:
;;       All cycles of your dependencies will be printed.
;;       Also there are more handy log messages and some bug fixes.
;;    v0.3-cycles:
;;       There are nice error messages about cycled dependencies now.
;;       Cycles printed in a way: pkg1 -> [pkg2 -> ...] pkg1.
;;       It means there is a cycle around pkg1.
;;    v0.2-auto-fetch:
;;       There is no need of explicit :ensure in your code now.
;;       When you req-package it adds :ensure if package is available in your repos.
;;       Also package deps :ensure'd automatically too.
;;       Just write (req-package pkg1 :require pkg2) and all you need will be installed.

;;; Code:

(eval-when-compile (require 'cl))
(require 'use-package)
(require 'package)
(require 'dash)
(require 'log4e)

(defgroup req-package nil
  "A package loading system"
  :group 'emacs)

(defcustom req-package-log-level 'warn
  "minimal log level. can be 'fatal, 'error, 'warn, 'info, 'debug, 'trace"
  :group 'req-package)

(defcustom req-package-detect-cycles t
  "detect dependency cycles"
  :group 'req-package
  :type 'boolean)

(defcustom req-package-error-on-cycle t
  "throw error if cycle is detected"
  :group 'req-package
  :type 'boolean)

(defvar req-package-reqs-reversed (make-hash-table :size 200)
  "package symbol -> list of packages dependent on it")

(defvar req-package-ranks (make-hash-table :size 200)
  "package symbol -> list of packages dependent on it")

(defvar req-package-evals (make-hash-table :size 200)
  "package symbol -> loading code prepared for evaluation")

(defvar req-package-visited (make-hash-table :size 200)
  "package symbol -> is it visited by cycle checktraversal")

(defvar req-package-cycles-count 0
  "number of cycles detected")

(defun req-package-wrap-reqs (reqs)
  "listify passed dependencies"
  (if (atom reqs) (list reqs) reqs))

(defun req-package-get-reqs (args acc)
  "extract dependencies from arg list"
  (if (null args)
      (list nil (reverse acc))
    (if (eq (car args) :require)
        (list (req-package-wrap-reqs (car (cdr args)))
              (append (reverse acc) (cddr args)))
      (req-package-get-reqs (cdr args) (cons (car args) acc)))))

(defun req-package-patch-config (name args)
  "patch :config section to invoke our callback"
  (if (null args)
      (list ':config (list 'req-package-loaded (list 'quote name)))
    (if (eq (car args) :config)
        (cons ':config
              (cons (list 'progn
                          (car (cdr args))
                          (list 'req-package-loaded (list 'quote name)))
                    (cddr args)))
      (cons (car args) (req-package-patch-config name (cdr args))))))

(defun req-package-eval (name)
  "evaluate package request"
  (let* ((EVAL (gethash name
                        req-package-evals
                        (append (req-package-gen-eval name)
                                (req-package-patch-config name
                                                          nil)))))
    (eval EVAL)))

(defun req-package-loaded (name)
  "callback for dependency graph load continuation"
  (req-package--log-info "package loaded: %s" name)
  (let* ((EVALS (-reduce-from 
                 (lambda (memo dependent)
                   (let* ((RANK (- (gethash dependent req-package-ranks 0) 1)))
                     (puthash dependent RANK req-package-ranks)
                     (if (eq 0 RANK) (cons dependent memo) memo)))
                 nil
                 (gethash name req-package-reqs-reversed nil))))
    (-each EVALS (lambda (name)
                   (puthash name -1 req-package-ranks)
                   (req-package-eval name)))))

(defmacro req-package (name &rest args)
  "add package to target list"
  `(let* ((NAME ',name)
          (ARGS ',args)
          (SPLIT (req-package-get-reqs ARGS nil))
          (USEPACKARGS (req-package-patch-config NAME (car (cdr SPLIT))))
          (REQS (car SPLIT)))

     (req-package--log-debug "package requested: %s" NAME)
     
     (-each REQS
       (lambda (req)
         (let* ((CURREQREV (gethash req req-package-reqs-reversed nil))
                (CURRANK (gethash NAME req-package-ranks 0)))
           (puthash req (cons NAME CURREQREV) req-package-reqs-reversed)
           (puthash req (gethash req req-package-ranks 0) req-package-ranks)
           (puthash NAME (+ CURRANK 1) req-package-ranks))))
     (puthash NAME (append (req-package-gen-eval NAME) USEPACKARGS) req-package-evals)
     (puthash NAME (gethash NAME req-package-ranks 0) req-package-ranks)
     (puthash NAME (gethash NAME req-package-reqs-reversed nil) req-package-reqs-reversed)))

(defmacro req-package-force (name &rest args)
  "immediatly load some package"
  `(let* ((NAME ',name)
          (ARGS ',args))

     (req-package--log-debug "package force-requested: %s" NAME)
     (eval (append (req-package-gen-eval NAME) ARGS))))

(defun req-package-gen-eval (package)
  "generate eval for package. if it is available in repo, add :ensure keyword"
  (let* ((ARCHIVES (if (null package-archive-contents)
                       (progn (package-refresh-contents)
                              package-archive-contents)
                     package-archive-contents))
         (AVAIL (-any? (lambda (elem)
                         (eq (car elem) package))
                       ARCHIVES))
         (EVAL (cond (AVAIL (list 'use-package package ':ensure package))
                     (t (list 'use-package package)))))
    EVAL))

(defun req-package-detect-cycles-traverse-impl (cur path)
  "traverse for cycles look up implementation"
  (puthash cur t req-package-visited)
  (if (not (-contains? path cur))
      (-each (gethash cur req-package-reqs-reversed nil)
        (lambda (dependent)
          (req-package-detect-cycles-traverse-impl dependent (cons cur path))))
    (progn (setq req-package-cycles-count (+ req-package-cycles-count 1))
           (req-package--log-error "cycle detected: %s" (cons cur path)))))

(defun req-package-detect-cycles-traverse ()
  "traverse for cycles look up"
  (maphash (lambda (key value)
             (if (null (gethash key req-package-visited nil))
                 (req-package-detect-cycles-traverse-impl key nil)))
           req-package-reqs-reversed)

  (if (and req-package-error-on-cycle (not (eq 0 req-package-cycles-count)))
      (error "%s cycle(s) detected. see M-x req-package--log-open-log"
             req-package-cycles-count)))

(defun req-package-finish ()
  "start loading process, call this after all req-package invocations"
  ;; (maphash (lambda (key value)
  ;;            (if (eq (gethash key req-package-ranks) -1)
  ;;                (progn (remhash key req-package-ranks)
  ;;                       (remhash key req-package-evals)
  ;;                       (remhash key req-package-reqs-reversed))))
  ;;          req-package-ranks)

  (if req-package-detect-cycles
      (progn (clrhash req-package-visited)
             (setq req-package-cycles-count 0)
             (req-package-detect-cycles-traverse)))
  
  (req-package--log-debug "package requests finished: %s packages are waiting"
                          (hash-table-count req-package-ranks))
  
  (maphash (lambda (key value)
             (if (eq (gethash key req-package-ranks 0) 0)
                 (progn (puthash key -1 req-package-ranks)
                        (req-package-eval key))))
           req-package-ranks))

(put 'req-package 'lisp-indent-function 'defun)

(defconst req-package-font-lock-keywords
  '(("(\\(req-package\\)\\_>[ \t']*\\(\\(?:\\sw\\|\\s_\\)+\\)?"
     (1 font-lock-keyword-face)
     (2 font-lock-constant-face nil t))))

(font-lock-add-keywords 'emacs-lisp-mode req-package-font-lock-keywords)

(log4e:deflogger "req-package" "%t [%l] %m" "%H:%M:%S")
(req-package--log-set-level req-package-log-level)
(req-package--log-enable-logging)
(req-package--log-clear-log)

(provide 'req-package)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; req-package.el ends here
