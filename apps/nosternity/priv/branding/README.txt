Optional public node branding assets

Place your logo and favicon in this directory before building the release.
They are served at /branding/<filename>. Configure node_logo_url and
node_favicon_url in the nosternity section of sys.config accordingly.

Example: logo.png here becomes /branding/logo.png. Use an absolute public
HTTPS URL for node_logo_url if Nostr clients should also receive it as the
NIP-11 icon. Root-relative URLs are used only by the web pages.

This directory is public: include only assets intended for visitors.
