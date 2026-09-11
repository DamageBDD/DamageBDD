#!/bin/bash

mkdir compressed
for img in *.png; do
    convert "$img" -resize 50% -quality 85 "compressed/$img"
done

latexmk -pdf -pdflatex="pdflatex -interaction=nonstopmode" billion_behemoth.tex
gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dBATCH -sOutputFile=billion_behemoth.optimized.pdf billion_behemoth.pdf
echo "PDF successfully optimized and saved as billion_behemoth.pdf"
