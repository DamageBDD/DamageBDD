#!/usr/bin/env python3
"""Local QR generation round trips, independently decoded with ZXing.

Run: python -m unittest discover -s apps/ecai/test -p test_personality_qr.py
Dependencies: node, Pillow, zxing-cpp (decoder tests skip if unavailable).
NODE or CODEX_PRIMARY_RUNTIME_NODE may supply the Node executable.
The BOLT11 examples come from https://github.com/lightning/bolts/blob/master/11-payment-encoding.md .
These are published test vectors, never payable production invoices.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

try:
    from PIL import Image, ImageDraw
    import zxingcpp
except ImportError:
    zxingcpp = None

ASSET = Path(__file__).resolve().parents[1] / "priv/static/js/vendor/ecai-qrcode.js"
NODE = os.environ.get("NODE") or os.environ.get("CODEX_PRIMARY_RUNTIME_NODE") or shutil.which("node")
INVOICES = [
    "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql",
    "lnbc9678785340p1pwmna7lpp5gc3xfm08u9qy06djf8dfflhugl6p7lgza6dsjxq454gxhj9t7a0sd8dgfkx7cmtwd68yetpd5s9xar0wfjn5gpc8qhrsdfq24f5ggrxdaezqsnvda3kkum5wfjkzmfqf3jkgem9wgsyuctwdus9xgrcyqcjcgpzgfskx6eqf9hzqnteypzxz7fzypfhg6trddjhygrcyqezcgpzfysywmm5ypxxjemgw3hxjmn8yptk7untd9hxwg3q2d6xjcmtv4ezq7pqxgsxzmnyyqcjqmt0wfjjq6t5v4khxsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygsxqyjw5qcqp2rzjq0gxwkzc8w6323m55m4jyxcjwmy7stt9hwkwe2qxmy8zpsgg7jcuwz87fcqqeuqqqyqqqqlgqqqqn3qq9q9qrsgqrvgkpnmps664wgkp43l22qsgdw4ve24aca4nymnxddlnp8vh9v2sdxlu5ywdxefsfvm0fq3sesf08uf6q9a2ke0hc9j6z6wlxg5z5kqpu2v9wz",
    "lnbc25m1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5vdhkven9v5sxyetpdeessp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9q5sqqqqqqqqqqqqqqqqsgq2qrqqqfppnqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqppnqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpp4qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhpnqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhp4qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspnqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsp4qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqnp5qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqnpkqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqz599y53s3ujmcfjp5xrdap68qxymkqphwsexhmhr8wdz5usdzkzrse33chw6dlp3jhuhge9ley7j2ayx36kawe7kmgg8sv5ugdyusdcqzn8z9x"
]


def render(values):
    script = r"""
      const fs = require('node:fs');
      (async () => {
        const source = fs.readFileSync(process.argv[1], 'utf8');
        const {invoiceQrSvg} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
        const values = JSON.parse(fs.readFileSync(0, 'utf8'));
        process.stdout.write(JSON.stringify(values.map(value => {
          try { return {svg: invoiceQrSvg(value)}; }
          catch (e) { return {error: e.message}; }
        })));
      })().catch(e => { console.error(e); process.exit(1); });
    """
    result = subprocess.run([NODE, "-e", script, str(ASSET)], input=json.dumps(values),
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


@unittest.skipUnless(NODE, "Node is required")
class InvoiceQrTest(unittest.TestCase):
    def test_malformed_inputs_are_rejected(self):
        invalid = [None, "", "javascript:alert(1)", "<svg onload=alert(1)>",
                   "LNbc" + INVOICES[0][4:], 'lnbc1abc" onload="bad' , "lnbc1" + "q" * 5000]
        self.assertTrue(all("error" in x for x in render(invalid)))

    def test_svg_has_quiet_zone_and_no_invoice_text_or_external_resources(self):
        result = render([INVOICES[0]])[0]
        svg = result["svg"]
        self.assertIn('viewBox="0 0 ', svg)
        self.assertIn('fill="#fff"', svg)
        self.assertIn('role="img"', svg)
        self.assertNotIn(INVOICES[0], svg)
        self.assertNotRegex(svg, r"<(?:script|image)|(?:href|onload|fetch)=")
        points = [(int(x), int(y)) for x, y in re.findall(r"M(\d+),(\d+)h1v1h-1z", svg)]
        dimension = int(re.search(r'viewBox="0 0 (\d+) \d+"', svg).group(1))
        self.assertEqual(min(x for x, _ in points), 4)
        self.assertEqual(min(y for _, y in points), 4)
        self.assertLess(max(x for x, _ in points), dimension - 4)
        self.assertLess(max(y for _, y in points), dimension - 4)

    @unittest.skipUnless(zxingcpp, "Install Pillow and zxing-cpp for independent QR decoding")
    def test_independent_decoder_recovers_complete_lightning_payload(self):
        # Exercise short, routed, long invoices plus URI/case normalization.
        inputs = INVOICES + ["lightning:" + INVOICES[0], INVOICES[1].upper()]
        for invoice, result in zip(inputs, render(inputs)):
            with self.subTest(length=len(invoice)):
                svg = result["svg"]
                dimension = int(re.search(r'viewBox="0 0 (\d+) \d+"', svg).group(1))
                image = Image.new("L", (dimension * 6, dimension * 6), 255)
                draw = ImageDraw.Draw(image)
                for x, y in re.findall(r"M(\d+),(\d+)h1v1h-1z", svg):
                    x, y = int(x) * 6, int(y) * 6
                    draw.rectangle((x, y, x + 5, y + 5), fill=0)
                decoded = zxingcpp.read_barcode(image)
                self.assertIsNotNone(decoded)
                expected = "LIGHTNING:" + re.sub(r"^lightning:", "", invoice, flags=re.I).upper()
                self.assertEqual(decoded.text, expected)


if __name__ == "__main__":
    unittest.main()
