using System.Text.Json;
using Tvoice.Windows.Sip;

namespace Tvoice.SipBridge;

internal static class Program
{
    private static readonly SemaphoreSlim OutputLock = new(1, 1);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static async Task Main()
    {
        Console.InputEncoding = System.Text.Encoding.UTF8;
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);

        await using var sip = new TvoiceSipRegistration();
        sip.StateChanged += (_, change) => _ = WriteAsync(new
        {
            type = "registration",
            state = RegistrationState(change.State),
            message = change.Message,
        });
        sip.CallChanged += (_, change) => _ = WriteAsync(new
        {
            type = "call",
            state = CallState(change.State),
            remoteNumber = change.PeerNumber,
            message = change.Message,
            connectedAtMillis = change.ConnectedAt?.ToUnixTimeMilliseconds(),
            muted = change.IsMuted,
            held = change.IsHeld,
        });

        while (await Console.In.ReadLineAsync() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            long? id = null;
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                id = root.GetProperty("id").GetInt64();
                var method = root.GetProperty("method").GetString() ?? string.Empty;
                var arguments = root.TryGetProperty("arguments", out var value) ? value : default;
                var result = await InvokeAsync(sip, method, arguments);
                await WriteAsync(new { id, ok = true, result });
                if (method == "shutdown") break;
            }
            catch (Exception exception)
            {
                await WriteAsync(new { id, ok = false, error = exception.Message });
            }
        }
    }

    private static async Task<object?> InvokeAsync(
        TvoiceSipRegistration sip,
        string method,
        JsonElement arguments)
    {
        switch (method)
        {
            case "register":
                await sip.RegisterAsync(RequiredString(arguments, "number"), RequiredString(arguments, "password"));
                return true;
            case "call":
                await sip.CallAsync(RequiredString(arguments, "number"));
                return null;
            case "answer":
                await sip.AcceptCallAsync();
                return null;
            case "reject":
            case "hangup":
                await sip.HangupAsync();
                return null;
            case "unregister":
                await sip.DisconnectAsync();
                return null;
            case "setMuted":
                sip.SetMuted(Bool(arguments, "muted"));
                return null;
            case "setHeld":
                await sip.SetHeldAsync(Bool(arguments, "held"));
                return null;
            case "setSpeaker":
                // Desktop Windows uses the current system playback device.
                return null;
            case "state":
                return new
                {
                    registrationState = sip.IsRegistered ? "Ok" : "Progress",
                    callState = CallState(sip.CallState),
                };
            case "shutdown":
                await sip.DisconnectAsync();
                return null;
            default:
                throw new ArgumentException($"Unknown SIP method: {method}");
        }
    }

    private static string RequiredString(JsonElement value, string name)
    {
        if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var property))
        {
            var result = property.GetString()?.Trim();
            if (!string.IsNullOrEmpty(result)) return result;
        }
        throw new ArgumentException($"Missing argument: {name}");
    }

    private static bool Bool(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var property) && property.GetBoolean();

    private static string RegistrationState(SipRegistrationState state) => state switch
    {
        SipRegistrationState.Connecting => "Progress",
        SipRegistrationState.Connected => "Ok",
        SipRegistrationState.Failed => "Failed",
        _ => "Unavailable",
    };

    private static string CallState(SipCallState state) => state switch
    {
        SipCallState.Incoming => "IncomingReceived",
        SipCallState.Calling => "OutgoingInit",
        SipCallState.Ringing => "OutgoingRinging",
        SipCallState.Connected => "StreamsRunning",
        SipCallState.Held => "Paused",
        SipCallState.Ended => "End",
        SipCallState.Failed => "Error",
        _ => "Idle",
    };

    private static async Task WriteAsync(object value)
    {
        await OutputLock.WaitAsync();
        try
        {
            await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value, JsonOptions));
            await Console.Out.FlushAsync();
        }
        finally
        {
            OutputLock.Release();
        }
    }
}
