;;; publish.el --- Static site generator for DamageBDD using Org Mode  -*- lexical-binding: t; -*-

;;; Commentary:
;; This script defines the publishing pipeline for the DamageBDD project.
;; It uses Org Mode and ox-publish to export .org files into static HTML,
;; injecting custom HTML snippets for <head>, preamble, and postamble.
;;
;; Snippets are read from the ./snippets directory, and publishing outputs to ./public.
;;
;; To use interactively:
;;   M-x damagebdd-publish
;;
;; Or in batch mode:
;;   emacs --script publish.el
;;

;;; Code:

(require 'ox-publish)
(require 'subr-x) ;; string-join, when-let, etc.

(defconst damagebdd-project-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(defun damagebdd-read-snippet (relative-path)
  "Read HTML snippet from RELATIVE-PATH under the project root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-path damagebdd-project-root))
    (buffer-string)))

(defvar damagebdd-html-head nil "HTML <head> section for DamageBDD export.")
(defvar damagebdd-html-preamble nil "HTML preamble for DamageBDD export.")
(defvar damagebdd-html-postamble nil "HTML postamble for DamageBDD export.")

(defun damagebdd-load-html-snippets ()
  "Load DamageBDD HTML snippets into defvars."
  (setq damagebdd-html-head      (damagebdd-read-snippet "snippets/header.html"))
  (setq damagebdd-html-preamble  (damagebdd-read-snippet "snippets/preamble.html"))
  (setq damagebdd-html-postamble (damagebdd-read-snippet "snippets/postamble.html"))
  (message "✅ HTML snippets loaded."))

(defun org-sitemap-date-entry-format (entry style project)
  "Format sitemap ENTRY in STYLE for PROJECT with a visible date."
  (let ((filename (org-publish-find-title entry project)))
    (if (= (length filename) 0)
        (format "*%s*" entry)
      (format "{{{timestamp(%s)}}} [[file:%s][%s]]"
              (format-time-string "%Y-%m-%d"
                                  (org-publish-find-date entry project))
              entry
              filename))))

;;; Settings
(setq org-export-global-macros
      '(("timestamp" . "@@html:<span class=\"timestamp\">[$1]</span>@@")))

(setq org-confirm-babel-evaluate nil
      org-html-validate-link nil
      org-export-in-background nil
      org-export-use-babel nil
      org-export-with-toc nil
      org-publish-use-timestamps-flag nil
      org-publish-timestamp-directory "~/.org-timestamps/"
      vc-handled-backends nil)

(fset 'yes-or-no-p (lambda (&rest _) t))
(fset 'y-or-n-p (lambda (&rest _) t))




;;;###autoload
(defun damagebdd-publish ()
  "Load HTML snippets and publish the DamageBDD site."
  (interactive)
  (damagebdd-load-html-snippets)
  (setq my-gpg-signing-key "DED5444526060D9F")
  (setq org-publish-project-alist
        `(
          ;; Run manifest generation once after all components finish.
          ("damagebdd"
           :components ("damagebdd.pages" "damagebdd.static" "damagebdd.articles" "damagebdd.papers"))

          ("damagebdd.pages"
           :base-directory ,(expand-file-name "org" damagebdd-project-root)
           :base-extension "org"
           :publishing-directory ,(expand-file-name "public" damagebdd-project-root)
           :recursive t
           :publishing-function org-html-publish-to-html
           :auto-preamble t
           :auto-sitemap t
           :auto-index t
           :sitemap-title "DamageBDD - BDD At Planetary Scale."
           :sitemap-filename "sitemap.org"
           :sitemap-sort-files anti-chronologically
           :makeindex t
           :sitemap-format-entry org-sitemap-date-entry-format
           :with-toc nil
           :html-doctype "html5"
           :html-html5-fancy t
           :html-head-include-scripts nil
           :html-head-include-default-style nil
           :html-head ,damagebdd-html-head
           :html-preamble ,damagebdd-html-preamble
           :html-postamble ,damagebdd-html-postamble)

          ("damagebdd.papers"
           :base-directory ,(expand-file-name "org/papers" damagebdd-project-root)
           :base-extension "jpeg\\|pdf"
           :publishing-directory ,(expand-file-name "public/papers" damagebdd-project-root)
           :recursive t
           :publishing-function org-publish-attachment)

          ("damagebdd.articles"
           :base-directory ,(expand-file-name "org/articles" damagebdd-project-root)
           :base-extension "jpeg\\|pdf"
           :publishing-directory ,(expand-file-name "public/articles" damagebdd-project-root)
           :recursive t
           :publishing-function org-publish-attachment)

          ("damagebdd.static"
           :base-directory ,(expand-file-name "assets" damagebdd-project-root)
           :base-extension "css\\|js\\|png\\|jpg\\|jpeg\\|gif\\|pdf\\|mp3\\|ogg\\|swf\\|ttf\\|map\\|svg\\|woff\\|woff2\\|ico\\|avif"
           :publishing-directory ,(expand-file-name "public/assets" damagebdd-project-root)
           :recursive t
           :publishing-function org-publish-attachment)
          ))
  (org-publish-project "damagebdd" t)
  (message "🚀 DamageBDD published."))

;;;###autoload
(defun publish-and-serve ()
  "Publish and serve the DamageBDD site locally using simple-httpd."
  (interactive)
  (damagebdd-publish)
  (add-to-list 'load-path (expand-file-name "scripts"))
  (require 'simple-httpd)
  (setq httpd-root (expand-file-name "public"))
  (setq httpd-port 8081)
  (unless (process-status "httpd")
    (message "🌐 Starting local server at http://localhost:8081")
    (httpd-start)))

(defun damagebdd-rsync-deploy (node)
  "Interactively select a NODE and deploy the 'public/' directory via rsync over SSH."
  (interactive
   (list (read-string "Enter user@node (e.g., root@node0): " "root@node0")))
  (damagebdd-publish)
  (let ((default-directory (expand-file-name "~/Org/damagebdd/")))
    (async-shell-command
     (format "rsync -avz --delete -e ssh public/ %s:/var/www/damagebdd.com/" node)
     "*DamageBDD Deploy*")))
(message "🛠️ DamageBDD publish.el loaded.")

(provide 'publish)

;;; publish.el ends here


