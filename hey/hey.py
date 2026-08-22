#!/usr/bin/env python3
"""
ghOSt hey — AI Voice & Text Assistant
Supports: Anthropic Claude, OpenAI GPT-4o, Google Gemini
Voice mode: BT mic → whisper.cpp → API → piper TTS → speaker
Text mode:  keyboard → API → terminal output
"""

import os
import sys
import json
import time
import signal
import argparse
import tempfile
import subprocess
import threading
from pathlib import Path
from datetime import datetime

# =============================================================================
# CONFIGURATION
# =============================================================================
CONFIG_DIR = Path.home() / ".config" / "ghost" / "hey"
CONFIG_FILE = CONFIG_DIR / "config.json"
HISTORY_DIR = Path.home() / ".local" / "share" / "ghost" / "conversations"
WHISPER_BIN = "/opt/ghost/whisper.cpp/main"
WHISPER_MODEL = "/opt/ghost/whisper.cpp/models/ggml-tiny.en.bin"
PIPER_BIN = "/opt/ghost/piper/piper"
PIPER_VOICE = "/opt/ghost/piper/voices/en_US-lessac-medium.onnx"
ARECORD_DEVICE = "default"
APLAY_DEVICE = "default"

DEFAULT_SYSTEM = """You are a helpful AI assistant running on ghOSt, 
a custom Linux OS for an Anbernic RG35XXH handheld device. 
The user is likely a security researcher or hacker. 
Be concise — responses will be read on a small screen or via TTS. 
Keep responses under 3 sentences unless detail is specifically requested."""

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================
def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    return {
        "default_model": "claude",
        "anthropic_key": "",
        "openai_key": "",
        "google_key": "",
        "voice_enabled": True,
        "tts_enabled": True,
        "history_enabled": True,
    }

def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    CONFIG_FILE.chmod(0o600)

def get_api_key(cfg, provider):
    """Get API key from config or pass store"""
    key = cfg.get(f"{provider}_key", "")
    if key:
        return key
    # Try pass
    try:
        result = subprocess.run(
            ["pass", f"ghost/hey/{provider}"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return result.stdout.strip().split('\n')[0]
    except:
        pass
    return ""

# =============================================================================
# API CALLS
# =============================================================================
def call_claude(messages, api_key, system=DEFAULT_SYSTEM):
    import urllib.request
    payload = json.dumps({
        "model": "claude-sonnet-4-20250514",
        "max_tokens": 1024,
        "system": system,
        "messages": messages
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            return data["content"][0]["text"]
    except Exception as e:
        return f"[Claude API error: {e}]"

def call_openai(messages, api_key, system=DEFAULT_SYSTEM):
    import urllib.request
    msgs = [{"role": "system", "content": system}] + messages
    payload = json.dumps({
        "model": "gpt-4o",
        "max_tokens": 1024,
        "messages": msgs
    }).encode()

    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            return data["choices"][0]["message"]["content"]
    except Exception as e:
        return f"[OpenAI API error: {e}]"

def call_gemini(messages, api_key, system=DEFAULT_SYSTEM):
    import urllib.request
    # Convert messages to Gemini format
    contents = []
    for msg in messages:
        role = "user" if msg["role"] == "user" else "model"
        contents.append({"role": role, "parts": [{"text": msg["content"]}]})

    payload = json.dumps({
        "system_instruction": {"parts": [{"text": system}]},
        "contents": contents,
        "generationConfig": {"maxOutputTokens": 1024}
    }).encode()

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={api_key}"
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            return data["candidates"][0]["content"]["parts"][0]["text"]
    except Exception as e:
        return f"[Gemini API error: {e}]"

def query_ai(text, messages, cfg):
    """Route to configured AI provider"""
    model = cfg.get("default_model", "claude")
    messages.append({"role": "user", "content": text})

    if model == "claude":
        key = get_api_key(cfg, "anthropic")
        if not key:
            return "[No Anthropic API key. Run: hey --setup]"
        response = call_claude(messages, key)
    elif model == "openai":
        key = get_api_key(cfg, "openai")
        if not key:
            return "[No OpenAI API key. Run: hey --setup]"
        response = call_openai(messages, key)
    elif model == "gemini":
        key = get_api_key(cfg, "google")
        if not key:
            return "[No Google API key. Run: hey --setup]"
        response = call_gemini(messages, key)
    else:
        response = "[Unknown model configured]"

    messages.append({"role": "assistant", "content": response})
    return response

# =============================================================================
# AUDIO: RECORDING & TTS
# =============================================================================
def check_bt_headset():
    """Check if BT headset with mic is connected"""
    try:
        result = subprocess.run(
            ["pactl", "list", "sources", "short"],
            capture_output=True, text=True
        )
        return "bluez" in result.stdout.lower()
    except:
        return False

def record_audio(duration=5):
    """Record from mic using arecord, return WAV file path"""
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
        subprocess.run([
            "arecord",
            "-D", ARECORD_DEVICE,
            "-f", "S16_LE",
            "-r", "16000",
            "-c", "1",
            "-d", str(duration),
            tmp.name
        ], check=True, capture_output=True)
        return tmp.name
    except subprocess.CalledProcessError:
        return None

def transcribe(wav_path):
    """Transcribe WAV file with whisper.cpp"""
    if not Path(WHISPER_BIN).exists():
        return None
    try:
        result = subprocess.run([
            WHISPER_BIN,
            "-m", WHISPER_MODEL,
            "-f", wav_path,
            "-np", "-nt",
            "--output-txt",
        ], capture_output=True, text=True, timeout=30)
        # whisper outputs to stdout
        text = result.stdout.strip()
        if not text:
            # Try reading the .txt output file
            txt_path = wav_path + ".txt"
            if Path(txt_path).exists():
                text = Path(txt_path).read_text().strip()
        return text if text else None
    except Exception as e:
        print(f"[whisper error: {e}]")
        return None

def speak(text):
    """Speak text via piper TTS → speaker"""
    if not Path(PIPER_BIN).exists():
        return
    try:
        piper_proc = subprocess.Popen([
            PIPER_BIN,
            "--model", PIPER_VOICE,
            "--output_raw"
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
           stderr=subprocess.DEVNULL)

        aplay_proc = subprocess.Popen([
            "aplay",
            "-r", "22050",
            "-f", "S16_LE",
            "-t", "raw",
            "-"
        ], stdin=piper_proc.stdout, stderr=subprocess.DEVNULL)

        piper_proc.stdin.write(text.encode())
        piper_proc.stdin.close()
        aplay_proc.wait()
    except Exception as e:
        print(f"[TTS error: {e}]")

# =============================================================================
# CONVERSATION HISTORY
# =============================================================================
def load_history(session_id=None):
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    if session_id:
        path = HISTORY_DIR / f"{session_id}.json"
        if path.exists():
            return json.loads(path.read_text())
    return []

def save_history(messages, session_id):
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    path = HISTORY_DIR / f"{session_id}.json"
    path.write_text(json.dumps(messages, indent=2))

# =============================================================================
# INTERACTIVE TEXT MODE
# =============================================================================
def text_mode(cfg, args):
    print("\033[0;36m ghOSt hey — text mode\033[0m")
    print(f"\033[0;90m model: {cfg.get('default_model', 'claude')} | Ctrl+C to exit\033[0m\n")

    session_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    messages = []

    while True:
        try:
            user_input = input("\033[0;32m you ▶\033[0m ").strip()
            if not user_input:
                continue
            if user_input.lower() in ("/exit", "/quit", "exit", "quit"):
                break
            if user_input.lower() == "/clear":
                messages = []
                print("\033[0;90m[conversation cleared]\033[0m")
                continue

            print("\033[0;90m[thinking...]\033[0m", end="\r")
            response = query_ai(user_input, messages, cfg)
            print(f"\033[0m        \r")
            print(f"\033[0;34m hey ▶\033[0m {response}\n")

            # TTS if enabled
            if cfg.get("tts_enabled") and args.speak:
                threading.Thread(target=speak, args=(response,), daemon=True).start()

            if cfg.get("history_enabled"):
                save_history(messages, session_id)

        except (KeyboardInterrupt, EOFError):
            print("\n\033[0;90m[session ended]\033[0m")
            break

# =============================================================================
# VOICE MODE
# =============================================================================
def voice_mode(cfg):
    print("\033[0;36m ghOSt hey — voice mode\033[0m")

    if not check_bt_headset():
        print("\033[1;33m[warn] No BT headset detected, falling back to text mode\033[0m")
        text_mode(cfg, argparse.Namespace(speak=True))
        return

    print(f"\033[0;90m model: {cfg.get('default_model', 'claude')} | BT mic active\033[0m")
    print("\033[0;90m Press Enter to speak, Ctrl+C to exit\033[0m\n")

    session_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    messages = []

    while True:
        try:
            input("\033[0;32m[Press Enter to speak]\033[0m")
            print("\033[0;31m🔴 Recording (5s)...\033[0m")

            wav = record_audio(duration=5)
            if not wav:
                print("[recording failed]")
                continue

            print("\033[0;90m[transcribing...]\033[0m", end="\r")
            text = transcribe(wav)
            Path(wav).unlink(missing_ok=True)

            if not text:
                print("[no speech detected]     ")
                continue

            print(f"\033[0;32m you ▶\033[0m {text}")
            print("\033[0;90m[thinking...]\033[0m", end="\r")

            response = query_ai(text, messages, cfg)
            print(f"\033[0m           \r")
            print(f"\033[0;34m hey ▶\033[0m {response}\n")

            # Speak response
            speak(response)

            if cfg.get("history_enabled"):
                save_history(messages, session_id)

        except (KeyboardInterrupt, EOFError):
            print("\n\033[0;90m[session ended]\033[0m")
            break

# =============================================================================
# MODEL SELECTOR
# =============================================================================
def select_model(cfg):
    models = ["claude", "openai", "gemini"]
    current = cfg.get("default_model", "claude")
    print("\n\033[0;36m Select AI model:\033[0m")
    for i, m in enumerate(models):
        marker = "▶" if m == current else " "
        print(f"  {marker} [{i+1}] {m}")
    try:
        choice = input("\nChoice (1-3): ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(models):
            cfg["default_model"] = models[idx]
            save_config(cfg)
            print(f"\033[0;32m[model set to {models[idx]}]\033[0m")
    except (ValueError, KeyboardInterrupt):
        pass

# =============================================================================
# SETUP
# =============================================================================
def setup(cfg):
    print("\n\033[0;36m ghOSt hey — setup\033[0m\n")
    print("API keys are stored encrypted via 'pass'")
    print("Leave blank to skip a provider\n")

    for provider, env_name in [
        ("anthropic", "Anthropic Claude"),
        ("openai", "OpenAI GPT-4o"),
        ("google", "Google Gemini"),
    ]:
        try:
            key = input(f"{env_name} API key: ").strip()
            if key:
                # Store in pass
                proc = subprocess.Popen(
                    ["pass", "insert", "-f", f"ghost/hey/{provider}"],
                    stdin=subprocess.PIPE
                )
                proc.communicate(input=f"{key}\n{key}\n".encode())
                print(f"\033[0;32m[{provider} key saved]\033[0m")
        except (KeyboardInterrupt, EOFError):
            break

    # Set default model
    select_model(cfg)
    print("\n\033[0;32m[setup complete]\033[0m\n")

# =============================================================================
# MAIN
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="ghOSt hey — AI assistant",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
  hey          Voice mode (requires BT headset mic)
  hey -t       Text mode (keyboard input, speaker output)
  hey -m       Select AI model
  hey --setup  Configure API keys
  hey -q "..."  Quick single query, no session
        """
    )
    parser.add_argument("-t", "--text",  action="store_true", help="Text input mode")
    parser.add_argument("-m", "--model", action="store_true", help="Select AI model")
    parser.add_argument("-s", "--speak", action="store_true", help="TTS output in text mode")
    parser.add_argument("--setup",       action="store_true", help="Configure API keys")
    parser.add_argument("-q", "--query", type=str, help="Quick single query")
    args = parser.parse_args()

    cfg = load_config()

    if args.setup:
        setup(cfg)
        return

    if args.model:
        select_model(cfg)
        return

    if args.query:
        # Quick single query
        response = query_ai(args.query, [], cfg)
        print(response)
        if args.speak:
            speak(response)
        return

    if args.text:
        text_mode(cfg, args)
    else:
        # Default: voice if headset present, else text
        voice_mode(cfg)


if __name__ == "__main__":
    main()
