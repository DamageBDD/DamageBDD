### DamageBDD Product Web Site

This repository contains the source files for the product page of [DamageBDD](https://damagebdd.com), a Behavior-Driven Development (BDD) framework at scale, leveraging the power of Emacs and Org mode. The site is generated using `org-publish`, a tool within Emacs that converts Org files into a static HTML site. The project follows a clean, minimalist approach, reflecting DamageBDD's commitment to transparent and verifiable software behavior.

### Instructions for Generating the Site


To generate the site from your Org files using the provided `org-publish` configuration, follow these steps:

```bash
git clone https://github.com/DamageBDD/DamageBDD.com
cd DamageBDD.com
```


```bash
emacs -Q --batch \
      -l scripts/publish.el \
      --eval "(org-publish-project \"damagebdd\" t)"
```

with docker 

```bash
docker run --rm -v "$PWD":/project -w /project silex/emacs:latest \
  emacs --batch \
  -l /project/scripts/publish.el \
  --eval "(org-publish-project \"damagebdd\" t)"
```

### Serve the Site


```bash
emacs -Q --fg-daemon -l scripts/publish.el --eval "(publish-and-serve)"
```
