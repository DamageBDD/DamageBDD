;;; bop.el --- Static site generator for Bitcoin Only Party using Org Mode  -*- lexical-binding: t; -*-

;;; Commentary:
;; This script defines the publishing pipeline for the Bitcoin Only Party project.
;; It uses Org Mode and ox-publish to export .org files into static HTML,
;; injecting custom HTML snippets for <head>, preamble, and postamble.
;;
;; Snippets are read from the ./snippets directory, and publishing outputs to ./public.
;;
;; To use interactively:
;;   M-x bop-publish
;;
;; Or in batch mode:
;;   emacs --script publish.el
;;

;;; Code:

(require 'ox-publish)

(defconst bop-project-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))


(defun bop-read-snippet (relative-path)
  "Read HTML snippet from RELATIVE-PATH under the project root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-path bop-project-root))
    (buffer-string)))



(defvar bop-html-head nil "HTML <head> section for Bitcoin Only Party export.")
(defvar bop-html-preamble nil "HTML preamble for Bitcoin Only Party export.")
(defvar bop-html-postamble nil "HTML postamble for Bitcoin Only Party export.")

(defun bop-load-html-snippets ()
  "Load Bitcoin Only Party HTML snippets into defvars."
  (setq bop-html-head      (bop-read-snippet "snippets/header.html"))
  (setq bop-html-preamble  (bop-read-snippet "snippets/preamble.html"))
  (setq bop-html-postamble (bop-read-snippet "snippets/postamble.html"))

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
(defun bop-publish ()
  "Load HTML snippets and publish the Bitcoin Only Party site."
  (interactive)
  (bop-load-html-snippets)
  (setq org-publish-project-alist
        `(
          ("bop" :components ("bop.pages" "bop.static"))
          ("bop.pages"
           :base-directory ,(expand-file-name "org" bop-project-root)

           :base-extension "org"
           :publishing-directory ,(expand-file-name "public" bop-project-root)
           :recursive t
           :publishing-function org-html-publish-to-html
           :auto-preamble t
           :auto-sitemap t
           :auto-index t
           :sitemap-title "Bitcoin Only Party - Finality. Integrity. Verification."
           :sitemap-filename "sitemap.org"
           :sitemap-sort-files anti-chronologically
           :makeindex t
           :sitemap-format-entry org-sitemap-date-entry-format
           :with-toc nil
           :html-doctype "html5"
           :html-html5-fancy t
           :html-head-include-scripts nil
           :html-head-include-default-style nil
           :html-head ,bop-html-head
           :html-preamble ,bop-html-preamble
           :html-postamble ,bop-html-postamble)
          ("bop.static"
           :base-directory ,(expand-file-name "assets" bop-project-root)
           :base-extension "css\\|js\\|png\\|jpg\\|jpeg\\|gif\\|pdf\\|mp3\\|ogg\\|swf\\|ttf\\|map\\|svg\\|woff\\|woff2\\|ico\\|avif"
           :publishing-directory ,(expand-file-name "public/assets" bop-project-root)
           :recursive t
           :publishing-function org-publish-attachment)
          ))
  (org-publish-project "bop" t)
  (message "🚀 Bitcoin Only Party published."))

;;;###autoload
(defun bop-publish-and-serve ()
  "Publish and serve the Bitcoin Only Party site locally using simple-httpd."
  (interactive)
  (bop-publish)
  (add-to-list 'load-path (expand-file-name "scripts"))
  (require 'simple-httpd)
  (setq httpd-root (expand-file-name "public"))
  (setq httpd-port 8081)
  (unless (process-status "httpd")
    (message "🌐 Starting local server at http://localhost:8081")
    (httpd-start)))
(defun bop-rsync-deploy (node)
  "Interactively select a NODE and deploy the 'public/' directory via rsync over SSH."
  (interactive
   (list (read-string "Enter user@node (e.g., root@node0): " "root@node0")))
  (setq my-gpg-signing-key "coordinator@bitcoinonly.party")
  (bop-publish)
  (let ((default-directory (expand-file-name "~/BitcoinOnlyParty")))
    (async-shell-command
     (format "rsync -avz --delete -e ssh public/ %s:/var/www/bitcoinonlyparty/" node)
     "*BoP Deploy*")))

(message "🛠️ Bitcoin Only Party publish.el loaded.")

(provide 'publish)

;;; publish.el ends here

