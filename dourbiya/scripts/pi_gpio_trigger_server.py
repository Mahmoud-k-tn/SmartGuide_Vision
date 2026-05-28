#!/usr/bin/env python3
import asyncio
import signal
from typing import Dict, Set

import websockets
from gpiozero import Button

HOST = "0.0.0.0"
PORT = 8765

PIN_TO_TRIGGER: Dict[int, str] = {
    17: "uni_library",
    27: "uni_cafeteria",
    22: "dorm_room_101",
    23: "stairs_down",
    24: "door_closed",
}

BOUNCE_TIME = 0.15
PULL_UP = True

connected_clients: Set[websockets.WebSocketServerProtocol] = set()
event_queue: asyncio.Queue[str] = asyncio.Queue()
buttons: Dict[int, Button] = {}
shutdown_event = asyncio.Event()


def on_button_pressed(trigger_id: str) -> None:
    try:
        loop = asyncio.get_running_loop()
        loop.call_soon_threadsafe(event_queue.put_nowait, trigger_id)
    except RuntimeError:
        pass


async def ws_handler(websocket):
    connected_clients.add(websocket)
    client = f"{websocket.remote_address}"
    print(f"[WS] Client connected: {client} | total={len(connected_clients)}")

    try:
        async for incoming in websocket:
            print(f"[WS RX] {incoming}")
    except websockets.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        print(f"[WS] Client disconnected: {client} | total={len(connected_clients)}")


async def broadcaster() -> None:
    while not shutdown_event.is_set():
        try:
            trigger_id = await asyncio.wait_for(event_queue.get(), timeout=0.25)
        except asyncio.TimeoutError:
            continue

        message = f"trigger:{trigger_id}"
        if not connected_clients:
            print(f"[GPIO] {trigger_id} (no clients connected)")
            continue

        dead_clients = []
        for ws in connected_clients:
            try:
                await ws.send(message)
            except Exception:
                dead_clients.append(ws)

        for ws in dead_clients:
            connected_clients.discard(ws)

        print(f"[TX] {message} -> {len(connected_clients)} client(s)")


def setup_gpio() -> None:
    for pin, trigger_id in PIN_TO_TRIGGER.items():
        button = Button(pin, pull_up=PULL_UP, bounce_time=BOUNCE_TIME)
        button.when_pressed = lambda t=trigger_id: on_button_pressed(t)
        buttons[pin] = button

    print("[GPIO] Buttons initialized:")
    for pin, trigger_id in PIN_TO_TRIGGER.items():
        print(f"  GPIO {pin} -> {trigger_id}")


def cleanup_gpio() -> None:
    for button in buttons.values():
        button.close()
    buttons.clear()
    print("[GPIO] Cleaned up.")


async def main() -> None:
    print(f"[BOOT] Starting GPIO trigger server on ws://{HOST}:{PORT}")
    setup_gpio()

    async with websockets.serve(ws_handler, HOST, PORT):
        print("[BOOT] WebSocket server ready.")
        broadcaster_task = asyncio.create_task(broadcaster())

        await shutdown_event.wait()

        broadcaster_task.cancel()
        try:
            await broadcaster_task
        except asyncio.CancelledError:
            pass

    cleanup_gpio()
    print("[BOOT] Server stopped.")


def request_shutdown() -> None:
    print("\n[BOOT] Shutdown requested...")
    shutdown_event.set()


if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, request_shutdown)
        except NotImplementedError:
            pass

    try:
        loop.run_until_complete(main())
    finally:
        loop.close()
