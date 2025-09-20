#!/usr/bin/env python3
"""
Kyutai STT Client - Version-agnostic WebSocket client
Compatible with all websockets library versions
"""

import argparse
import asyncio
import json
import signal
import sys
import inspect

import msgpack
import numpy as np
import sounddevice as sd
import websockets

SAMPLE_RATE = 24000
PAUSE_PREDICTION_HEAD_INDEX = 2

def get_websockets_connect_kwargs(headers):
    """
    Auto-detect the correct parameter name for headers based on websockets version.
    Returns kwargs dict with the correct parameter name.
    """
    try:
        sig = inspect.signature(websockets.connect)
        params = list(sig.parameters.keys())
        
        if 'additional_headers' in params:
            print(f"Using websockets {websockets.__version__} with additional_headers")
            return {'additional_headers': headers}
        elif 'extra_headers' in params:
            print(f"Using websockets {websockets.__version__} with extra_headers")
            return {'extra_headers': headers}
        else:
            print(f"Warning: websockets {websockets.__version__} - no header parameter found")
            return {}
    except Exception as e:
        print(f"Warning: Could not detect websockets API: {e}")
        # Fallback to additional_headers (older versions)
        return {'additional_headers': headers}

async def receive_messages(websocket, show_vad: bool = False):
    """Receive and process messages from the WebSocket server."""
    try:
        speech_started = False
        async for message in websocket:
            # Handle both msgpack (direct moshi-server) and JSON (FastAPI wrapper) formats
            try:
                if isinstance(message, str):
                    # JSON message from FastAPI wrapper
                    data = json.loads(message)
                else:
                    # Binary msgpack message from direct moshi-server
                    data = msgpack.unpackb(message, raw=False)
            except (json.JSONDecodeError, msgpack.exceptions.ExtraData) as e:
                print(f"Error decoding message: {e}")
                continue

            # Handle connection confirmation from FastAPI wrapper
            if data.get("type") == "connected":
                print(f"\n✅ Connected: {data.get('message', 'Ready')}")
                continue
            
            # Handle word messages from FastAPI wrapper
            elif data.get("type") == "word":
                print(data["text"], end=" ", flush=True)
                speech_started = True
                continue
            
            # Handle error messages
            elif data.get("type") == "error":
                print(f"\n❌ Error: {data.get('message', 'Unknown error')}")
                continue

            # The Step message only gets sent if the model has semantic VAD available (direct connection)
            if data.get("type") == "Step" and show_vad:
                pause_prediction = data["prs"][PAUSE_PREDICTION_HEAD_INDEX]
                if pause_prediction > 0.5 and speech_started:
                    print("| ", end="", flush=True)
                    speech_started = False

            elif data.get("type") == "Word":
                print(data["text"], end=" ", flush=True)
                speech_started = True
    except websockets.ConnectionClosed:
        print("\nConnection closed while receiving messages.")

async def send_messages(websocket, audio_queue):
    """Send audio data from microphone to WebSocket server."""
    try:
        # Start by draining the queue to avoid lags
        while not audio_queue.empty():
            await audio_queue.get()

        print("Starting the transcription")

        while True:
            audio_data = await audio_queue.get()
            chunk = {"type": "Audio", "pcm": [float(x) for x in audio_data]}
            
            # Check if we're connected to production FastAPI (based on URL detection)
            # The production API expects JSON text, direct moshi-server expects msgpack binary
            try:
                # Try sending as JSON first (for FastAPI wrapper)
                await websocket.send(json.dumps(chunk))
            except Exception:
                # Fallback to msgpack (for direct moshi-server)
                msg = msgpack.packb(chunk, use_bin_type=True, use_single_float=True)
                await websocket.send(msg)

    except websockets.ConnectionClosed:
        print("Connection closed while sending messages.")

async def stream_audio(url: str, api_key: str, show_vad: bool):
    """Stream audio data to a WebSocket server."""
    print("Starting microphone recording...")
    print("Press Ctrl+C to stop recording")
    audio_queue = asyncio.Queue()

    loop = asyncio.get_event_loop()

    def audio_callback(indata, frames, time, status):
        loop.call_soon_threadsafe(
            audio_queue.put_nowait, indata[:, 0].astype(np.float32).copy()
        )

    # Start audio stream
    with sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        callback=audio_callback,
        blocksize=1920,  # 80ms blocks
    ):
        headers = {"kyutai-api-key": api_key}
        
        # Auto-detect the correct header parameter name
        connect_kwargs = get_websockets_connect_kwargs(headers)
        
        # Connect with version-appropriate parameters
        async with websockets.connect(url, **connect_kwargs) as websocket:
            send_task = asyncio.create_task(send_messages(websocket, audio_queue))
            receive_task = asyncio.create_task(
                receive_messages(websocket, show_vad=show_vad)
            )
            await asyncio.gather(send_task, receive_task)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Real-time microphone transcription (version-agnostic)")
    parser.add_argument(
        "--url",
        help="The URL of the server to which to send the audio",
        default="ws://127.0.0.1:8080",
    )
    parser.add_argument("--api-key", default="public_token")
    parser.add_argument(
        "--list-devices", action="store_true", help="List available audio devices"
    )
    parser.add_argument(
        "--device", type=int, help="Input device ID (use --list-devices to see options)"
    )
    parser.add_argument(
        "--show-vad",
        action="store_true",
        help="Visualize the predictions of the semantic voice activity detector with a '|' symbol",
    )

    args = parser.parse_args()

    def handle_sigint(signum, frame):
        print("Interrupted by user")
        exit(0)

    signal.signal(signal.SIGINT, handle_sigint)

    if args.list_devices:
        print("Available audio devices:")
        print(sd.query_devices())
        exit(0)

    if args.device is not None:
        sd.default.device[0] = args.device

    # Auto-detect URL format: production FastAPI vs direct moshi-server
    if "/ws/live" in args.url:
        # Production FastAPI wrapper - use URL as-is
        url = args.url
        print(f"Connecting to production API: {url}")
    else:
        # Direct moshi-server connection - append /api/asr-streaming
        url = f"{args.url}/api/asr-streaming"
        print(f"Connecting to direct moshi-server: {url}")
    
    asyncio.run(stream_audio(url, args.api_key, args.show_vad))
