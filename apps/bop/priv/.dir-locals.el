;; ~/BitcoinOnlyParty/.dir-locals.el
((org-mode
  . ((eval . (load-file (expand-file-name "scripts/bop.el"
                                          (locate-dominating-file buffer-file-name ".dir-locals.el")))))))
