#!/usr/bin/env python3
"""Local public-fixture resident Whisper benchmark. No microphone/network/downloads.
Model startup and warm overlapping-window latency are reported separately.
"""
import argparse, hashlib, json, pathlib, platform, select, struct, subprocess, time, wave
from benchmark import words, edit_distance

def sha(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def line(process, timeout=120):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]: break
        char = process.stdout.read(1)
        if not char: raise RuntimeError('Helper exited')
        if char == b'\n': return json.loads(data)
        data += char
        if len(data) > 262144: raise RuntimeError('Response limit')
    raise TimeoutError('Helper timed out')
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', required=True); parser.add_argument('--model', required=True)
    parser.add_argument('--audio', default='/opt/homebrew/share/whisper.cpp/jfk.wav')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with wave.open(args.audio) as audio:
        assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
        values = [x / 32768 for x in struct.unpack('<' + 'h' * audio.getnframes(), audio.readframes(audio.getnframes()))]
    began = time.monotonic()
    process = subprocess.Popen([args.helper, args.model, 'en'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    windows = []
    try:
        ready = line(process)
        assert ready == {'ready': True, 'protocol': 1}
        startup = time.monotonic() - began
        original_pcm = struct.pack('<I', len(values)) + struct.pack('<' + 'f' * len(values), *values)
        began = time.monotonic(); process.stdin.write(original_pcm); process.stdin.flush()
        original_result = line(process, 60)
        original_seconds = time.monotonic() - began
        hypothesis = ' '.join(part['text'].strip() for part in original_result['segments'])
        reference = 'And so my fellow Americans ask not what your country can do for you ask what you can do for your country'
        original_wer = edit_distance(words(reference), words(hypothesis)) / len(words(reference))
        assert original_wer <= 0.15, f'Public JFK full-fixture WER {original_wer}'
        # Repeat the same real public recording over time to exercise >24s rolling coverage.
        stream = values * 4
        for end in list(range(48000, len(stream), 48000)) + [len(stream)]:
            start = max(0, end - 192000)
            pcm = stream[start:end]
            payload = struct.pack('<I', len(pcm)) + struct.pack('<' + 'f' * len(pcm), *pcm)
            began = time.monotonic()
            process.stdin.write(payload); process.stdin.flush()
            result = line(process, 60)
            assert isinstance(result.get('segments'), list)
            windows.append({'start': start/16000, 'end': end/16000, 'seconds': time.monotonic()-began, 'segments': result['segments']})
        # Digital silence must be a no-op, even in the previously active context.
        process.stdin.write(struct.pack('<I', 16000) + bytes(64000)); process.stdin.flush()
        silence = line(process)
        assert silence.get('silent') and silence['segments'] == []
        process.stdin.write(bytes(4)); process.stdin.flush()
        process.wait(timeout=5)
        assert process.returncode == 0
    finally:
        if process.poll() is None: process.kill(); process.wait()
    result = {'fixture': 'public whisper.cpp JFK; repeated 4x (not new independent samples)', 'platform': platform.platform(), 'model_sha256': sha(args.model), 'helper_sha256': sha(args.helper), 'audio_sha256': sha(args.audio), 'model_load_seconds': startup, 'warm_windows': windows, 'full_fixture_warm_seconds': original_seconds, 'full_fixture_text': hypothesis, 'full_fixture_wer': original_wer, 'silence_noop': True, 'audio_upload': False, 'claims': 'Provisional windows only. No microphone or representative accuracy/latency claim.'}
    pathlib.Path(args.output).write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'load_seconds':startup, 'windows':len(windows), 'median_window_seconds':sorted(x['seconds'] for x in windows)[len(windows)//2], 'output':args.output}))
if __name__ == '__main__': main()
