using NAudio.Wave;

namespace Tvoice.Windows.Services;

public sealed class RingtonePlayer : IDisposable
{
    private WaveOutEvent? _output;

    public void Start()
    {
        Stop();
        try
        {
            _output = new WaveOutEvent { DesiredLatency = 100, NumberOfBuffers = 3 };
            _output.Init(new CadencedRingProvider());
            _output.Play();
        }
        catch
        {
            Stop();
        }
    }

    public void Stop()
    {
        var output = _output;
        _output = null;
        if (output is null) return;
        try { output.Stop(); } catch { }
        output.Dispose();
    }

    public void Dispose() => Stop();

    private sealed class CadencedRingProvider : IWaveProvider
    {
        private const int SampleRate = 8000;
        private long _sample;
        public WaveFormat WaveFormat { get; } = new(SampleRate, 16, 1);

        public int Read(byte[] buffer, int offset, int count)
        {
            var samples = count / 2;
            for (var index = 0; index < samples; index++, _sample++)
            {
                var cadence = (_sample % (SampleRate * 5L)) / (double)SampleRate;
                var active = cadence < 1.2;
                var time = _sample / (double)SampleRate;
                var value = active
                    ? (short)(3600 * (Math.Sin(2 * Math.PI * 440 * time) + Math.Sin(2 * Math.PI * 480 * time)))
                    : (short)0;
                buffer[offset + index * 2] = (byte)(value & 0xff);
                buffer[offset + index * 2 + 1] = (byte)((value >> 8) & 0xff);
            }
            return samples * 2;
        }
    }
}
