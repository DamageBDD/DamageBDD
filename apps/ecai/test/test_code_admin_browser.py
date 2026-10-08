"""Compatibility entrypoint for the current node-admin console browser suite.

The old table-oriented review mock was superseded by expandable patch cards and
server-explained publisher gates. Run the full newer smoke test here.
"""
import asyncio
from test_code_metrics_browser import main

if __name__ == "__main__":
    asyncio.run(main())
