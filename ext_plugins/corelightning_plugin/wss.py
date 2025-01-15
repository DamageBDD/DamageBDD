#!/usr/sbin/python
import sys
import asyncio
import websockets


async def communicate_with_websocket(uri):
    async with websockets.connect(uri) as websocket:
        while True:
            try:
                # Read input from stdin
                user_input = sys.stdin.readline().strip()
                if not user_input:
                    continue

                # Send input to WebSocket
                await websocket.send(user_input)

                # Receive response from WebSocket
                response = await websocket.recv()

                # Write response to stdout
                print(response, flush=True)

            except (websockets.ConnectionClosed, KeyboardInterrupt):
                print("Connection closed or interrupted.", file=sys.stderr)
                break


if __name__ == "__main__":
    # if len(sys.argv) != 2:
    #    print(f"Usage: {sys.argv[0]} <websocket_uri>", file=sys.stderr)
    #    sys.exit(1)

    # websocket_uri = sys.argv[1]
    websocket_uri = "ws://localhost:8080/_cln/"
    asyncio.run(communicate_with_websocket(websocket_uri))
