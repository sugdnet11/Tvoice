using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using NAudio.Wave;

namespace Tvoice.Windows.Sip;

public enum AudioCodec
{
    Pcma = 8,
    Pcmu = 0,
}

public sealed record RemoteAudioMedia(IPEndPoint Endpoint, AudioCodec Codec, int? TelephoneEventPayload)
{
    public static RemoteAudioMedia? FromSdp(string sdp, IPAddress fallbackAddress)
    {
        IPAddress? sessionAddress = null;
        IPAddress? audioAddress = null;
        int? port = null;
        var payloads = new List<int>();
        var rtpMaps = new Dictionary<int, string>();
        var inAudio = false;
        var mediaStarted = false;
        var transportSupported = false;

        foreach (var sourceLine in sdp.Split('\n'))
        {
            var line = sourceLine.Trim();
            if (line.StartsWith("m=", StringComparison.OrdinalIgnoreCase))
            {
                mediaStarted = true;
                inAudio = line.StartsWith("m=audio ", StringComparison.OrdinalIgnoreCase);
                if (!inAudio) continue;
                var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                port = int.TryParse(fields.ElementAtOrDefault(1)?.Split('/')[0], out var parsedPort) ? parsedPort : null;
                transportSupported = fields.ElementAtOrDefault(2)?.ToUpperInvariant() is "RTP/AVP" or "RTP/AVPF";
                payloads = fields.Skip(3).Select(value => int.TryParse(value, out var parsed) ? parsed : -1)
                    .Where(value => value >= 0).ToList();
            }
            else if (line.StartsWith("c=IN IP4 ", StringComparison.OrdinalIgnoreCase))
            {
                var host = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                if (IPAddress.TryParse(host, out var parsed))
                {
                    if (inAudio) audioAddress = parsed;
                    else if (!mediaStarted) sessionAddress = parsed;
                }
            }
            else if (inAudio && line.StartsWith("a=rtpmap:", StringComparison.OrdinalIgnoreCase))
            {
                var mapping = line[9..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (mapping.Length >= 2 && int.TryParse(mapping[0], out var payload))
                    rtpMaps[payload] = mapping[1].Split('/')[0].ToUpperInvariant();
            }
        }

        if (!transportSupported || port is not >= 1 or > 65535) return null;
        var codec = payloads.Contains(8) || rtpMaps.Any(item => payloads.Contains(item.Key) && item.Value == "PCMA")
            ? AudioCodec.Pcma
            : payloads.Contains(0) || rtpMaps.Any(item => payloads.Contains(item.Key) && item.Value == "PCMU")
                ? AudioCodec.Pcmu
                : (AudioCodec?)null;
        if (codec is null) return null;
        var telephoneEvent = rtpMaps
            .Where(item => payloads.Contains(item.Key) && item.Value == "TELEPHONE-EVENT")
            .Select(item => (int?)item.Key)
            .FirstOrDefault();
        return new RemoteAudioMedia(
            new IPEndPoint(audioAddress ?? sessionAddress ?? fallbackAddress, port.Value),
            codec.Value,
            telephoneEvent);
    }
}

public sealed class RtpAudioSession : IAsyncDisposable
{
    private const int SamplesPerPacket = 160;
    private readonly UdpClient _socket = new(new IPEndPoint(IPAddress.Any, 0));
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _captureLock = new();
    private readonly Queue<byte> _captureBytes = new();
    private readonly uint _ssrc = BinaryPrimitives.ReadUInt32BigEndian(RandomNumberGenerator.GetBytes(4));
    private WaveInEvent? _capture;
    private WaveOutEvent? _playback;
    private BufferedWaveProvider? _playbackBuffer;
    private Task? _receiveTask;
    private IPEndPoint? _remote;
    private AudioCodec _codec;
    private int? _telephoneEventPayload;
    private ushort _sequence = (ushort)Random.Shared.Next(ushort.MaxValue + 1);
    private uint _timestamp = (uint)Random.Shared.NextInt64(uint.MaxValue);
    private IPAddress? _pinnedAddress;
    private int? _pinnedPort;
    private uint? _pinnedSsrc;
    private bool _started;
    private bool _muted;
    private bool _held;
    private long _captureAllowedAt;
    private long _playbackAllowedAt;

    public int LocalPort => ((IPEndPoint)_socket.Client.LocalEndPoint!).Port;
    public bool IsMuted => _muted;
    public bool IsHeld => _held;

    public void Configure(RemoteAudioMedia media)
    {
        _remote = media.Endpoint;
        _codec = media.Codec;
        _telephoneEventPayload = media.TelephoneEventPayload;
        _pinnedAddress = null;
        _pinnedPort = null;
        _pinnedSsrc = null;
    }

    public void Start()
    {
        if (_started) return;
        if (_remote is null) throw new InvalidOperationException("В SDP отсутствуют поддерживаемые параметры аудио.");
        _started = true;
        _captureAllowedAt = Environment.TickCount64 + 1100;
        _playbackAllowedAt = Environment.TickCount64 + 450;

        _playbackBuffer = new BufferedWaveProvider(new WaveFormat(8000, 16, 1))
        {
            BufferDuration = TimeSpan.FromMilliseconds(400),
            DiscardOnBufferOverflow = true,
            ReadFully = true,
        };
        _playback = new WaveOutEvent { DesiredLatency = 100, NumberOfBuffers = 3 };
        _playback.Init(_playbackBuffer);
        _playback.Play();

        _capture = new WaveInEvent
        {
            DeviceNumber = 0,
            WaveFormat = new WaveFormat(8000, 16, 1),
            BufferMilliseconds = 20,
            NumberOfBuffers = 4,
        };
        _capture.DataAvailable += OnCaptured;
        _capture.StartRecording();
        _receiveTask = ReceiveLoopAsync(_lifetime.Token);
    }

    public void SetMuted(bool muted) => _muted = muted;

    public void SetHeld(bool held)
    {
        _held = held;
        if (!held)
        {
            _captureAllowedAt = Environment.TickCount64 + 1100;
            _playbackAllowedAt = Environment.TickCount64 + 450;
            _playbackBuffer?.ClearBuffer();
        }
    }

    public async Task SendDtmfAsync(char digit, CancellationToken cancellationToken = default)
    {
        var payloadType = _telephoneEventPayload;
        var remote = _remote;
        if (payloadType is null || remote is null) return;
        var eventCode = digit switch
        {
            >= '0' and <= '9' => digit - '0',
            '*' => 10,
            '#' => 11,
            'A' or 'a' => 12,
            'B' or 'b' => 13,
            'C' or 'c' => 14,
            'D' or 'd' => 15,
            _ => -1,
        };
        if (eventCode < 0) return;
        var eventTimestamp = _timestamp;
        for (var index = 0; index < 6; index++)
        {
            var end = index >= 3;
            var duration = (ushort)(160 * Math.Min(index + 1, 4));
            var payload = new byte[4];
            payload[0] = (byte)eventCode;
            payload[1] = (byte)((end ? 0x80 : 0) | 10);
            BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(2), duration);
            await SendPacketAsync((byte)payloadType.Value, payload, eventTimestamp, cancellationToken);
            await Task.Delay(20, cancellationToken);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        if (_capture is not null)
        {
            _capture.DataAvailable -= OnCaptured;
            try { _capture.StopRecording(); } catch { }
            _capture.Dispose();
        }
        _playback?.Stop();
        _playback?.Dispose();
        _socket.Dispose();
        if (_receiveTask is not null)
            try { await _receiveTask; } catch { }
        _lifetime.Dispose();
    }

    private void OnCaptured(object? sender, WaveInEventArgs args)
    {
        if (!_started || _muted || _held || Environment.TickCount64 < _captureAllowedAt) return;
        lock (_captureLock)
        {
            foreach (var value in args.Buffer.AsSpan(0, args.BytesRecorded)) _captureBytes.Enqueue(value);
            while (_captureBytes.Count >= SamplesPerPacket * 2)
            {
                var pcm = new byte[SamplesPerPacket * 2];
                for (var index = 0; index < pcm.Length; index++) pcm[index] = _captureBytes.Dequeue();
                _ = SendAudioAsync(pcm, _lifetime.Token);
            }
        }
    }

    private async Task SendAudioAsync(byte[] pcm, CancellationToken cancellationToken)
    {
        var payload = new byte[SamplesPerPacket];
        for (var index = 0; index < SamplesPerPacket; index++)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(index * 2, 2));
            payload[index] = _codec == AudioCodec.Pcma ? G711.EncodeAlaw(sample) : G711.EncodeUlaw(sample);
        }
        var timestamp = _timestamp;
        _timestamp += SamplesPerPacket;
        await SendPacketAsync((byte)_codec, payload, timestamp, cancellationToken);
    }

    private async Task SendPacketAsync(byte payloadType, byte[] payload, uint timestamp, CancellationToken cancellationToken)
    {
        var remote = _remote;
        if (remote is null) return;
        var packet = new byte[12 + payload.Length];
        packet[0] = 0x80;
        packet[1] = payloadType;
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(2), _sequence++);
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(4), timestamp);
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(8), _ssrc);
        payload.CopyTo(packet, 12);
        try { await _socket.SendAsync(packet, remote, cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var received = await _socket.ReceiveAsync(cancellationToken);
                if (received.Buffer.Length < 12 || (received.Buffer[0] >> 6) != 2) continue;
                if (_pinnedAddress is not null &&
                    (!_pinnedAddress.Equals(received.RemoteEndPoint.Address) || _pinnedPort != received.RemoteEndPoint.Port)) continue;
                var csrcCount = received.Buffer[0] & 0x0f;
                var hasExtension = (received.Buffer[0] & 0x10) != 0;
                var offset = 12 + csrcCount * 4;
                if (offset > received.Buffer.Length) continue;
                if (hasExtension)
                {
                    if (offset + 4 > received.Buffer.Length) continue;
                    var extensionWords = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer.AsSpan(offset + 2, 2));
                    offset += 4 + extensionWords * 4;
                }
                if (offset >= received.Buffer.Length) continue;
                var payloadType = received.Buffer[1] & 0x7f;
                if (payloadType != (int)_codec) continue;
                var ssrc = BinaryPrimitives.ReadUInt32BigEndian(received.Buffer.AsSpan(8, 4));
                if (_pinnedSsrc is not null && _pinnedSsrc != ssrc) continue;
                _pinnedAddress ??= received.RemoteEndPoint.Address;
                _pinnedPort ??= received.RemoteEndPoint.Port;
                _pinnedSsrc ??= ssrc;
                if (_held || Environment.TickCount64 < _playbackAllowedAt) continue;

                var payloadLength = received.Buffer.Length - offset;
                var pcm = new byte[payloadLength * 2];
                for (var index = 0; index < payloadLength; index++)
                {
                    var encoded = received.Buffer[offset + index];
                    var sample = _codec == AudioCodec.Pcma ? G711.DecodeAlaw(encoded) : G711.DecodeUlaw(encoded);
                    BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(index * 2, 2), sample);
                }
                _playbackBuffer?.AddSamples(pcm, 0, pcm.Length);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
    }
}
