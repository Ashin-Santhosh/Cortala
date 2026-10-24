/* A mono PCM stream at the AudioContext's actual 16 kHz rate. No audio is played. */
class MonoPCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Float32Array(16000);
    this.offset = 0;
    this.ended = false;
    this.levelFrames = 0;
    this.port.onmessage = ({ data }) => {
      if (data === 'flush') {
        if (this.offset) this.port.postMessage({ type: 'pcm', samples: this.buffer.slice(0, this.offset) });
        this.offset = 0;
        this.ended = true;
        this.port.postMessage({ type: 'flushed' });
      }
    };
  }
  process(inputs, outputs) {
    for (const output of outputs) for (const channel of output) channel.fill(0);
    if (this.ended) return false;
    const channels = inputs[0];
    if (!channels || !channels.length) return true;
    const frames = channels[0].length;
    let energy = 0;
    for (let i = 0; i < frames; i++) {
      let sample = 0;
      for (const channel of channels) sample += channel[i] || 0;
      sample /= channels.length;
      this.buffer[this.offset++] = sample;
      energy += sample * sample;
      if (this.offset === this.buffer.length) {
        this.port.postMessage({ type: 'pcm', samples: this.buffer });
        this.buffer = new Float32Array(16000);
        this.offset = 0;
      }
    }
    if (++this.levelFrames % 8 === 0) this.port.postMessage({ type: 'level', level: Math.min(1, Math.sqrt(energy / Math.max(1, frames)) * 5) });
    return true;
  }
}
registerProcessor('mono-pcm', MonoPCMProcessor);
