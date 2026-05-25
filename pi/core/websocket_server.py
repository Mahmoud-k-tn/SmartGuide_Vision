# core/websocket_server.py -- Pi to Phone WebSocket server

import asyncio
import json
import websockets
from core.config import WS_HOST, WS_PORT

_clients = set()


async def handler(websocket):
    global _clients
    _clients.add(websocket)
    print('[WS] Phone connected: ' + str(websocket.remote_address))
    try:
        async for message in websocket:
            await _on_message(websocket, message)
    except websockets.ConnectionClosed:
        pass
    finally:
        _clients.discard(websocket)
        print('[WS] Phone disconnected: ' + str(websocket.remote_address))


async def _on_message(websocket, raw):
    global _clients
    try:
        msg = json.loads(raw)
        msg_type = msg.get('type', '')

        if msg_type == 'gps_update':
            lat = msg.get('lat', 0)
            lng = msg.get('lng', 0)
            print('[WS] GPS update: ' + str(lat) + ', ' + str(lng))

        elif msg_type == 'start_indoor':
            monument = msg.get('monument', '')
            print('[WS] Start indoor SLAM for: ' + monument)

        else:
            print('[WS] Unknown message type: ' + msg_type)

    except json.JSONDecodeError:
        print('[WS] Invalid JSON: ' + str(raw))


async def broadcast(message):
    global _clients
    if not _clients:
        return
    raw = json.dumps(message)
    disconnected = set()
    for client in _clients:
        try:
            await client.send(raw)
        except websockets.ConnectionClosed:
            disconnected.add(client)
    _clients -= disconnected


async def start_server():
    print('[WS] Server starting on ' + WS_HOST + ':' + str(WS_PORT))
    async with websockets.serve(handler, WS_HOST, WS_PORT):
        print('[WS] Listening on ws://' + WS_HOST + ':' + str(WS_PORT))
        await asyncio.Future()
